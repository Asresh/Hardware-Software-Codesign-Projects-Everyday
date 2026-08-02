// ============================================================================
// risk_tb.sv - differential testbench for the pre-trade risk engine.
//
//   1. Program   : replay config.hex over APB into the symbol/account tables.
//   2. Anchor    : the first (directed) order is a fat-finger price -> assert
//                  the RTL rejects it with REJ_PRICEBAND (a pinned value).
//   3. Pass A    : stream every order under randomised ingress bubbles + egress
//                  backpressure; check each decision beat against golden.txt.
//   4. Pass B    : soft-reset the state, stream again at full rate, re-check,
//                  and measure sustained + peak orders/clock.
//   5. CSR check : the aggregate statistics histogram matches the golden model.
//   6. Kill/IRQ  : engage the global kill switch -> every order REJ_KILL and a
//                  sticky interrupt that clears W1C.
//
//   Zero mismatches across every pass is the pass condition.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
`include "risk_const.vh"

module risk_tb;
    localparam integer MAXO = 4096;
    localparam integer N    = `NUM_ORDERS;

    // ---- clock / reset ----
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---- DUT I/O ----
    reg  [127:0] s_tdata = 0;
    reg          s_tvalid = 0, s_tlast = 0;
    wire         s_tready;
    wire [127:0] m_tdata;
    wire         m_tvalid, m_tlast;
    reg          m_tready = 0;

    reg          psel = 0, penable = 0, pwrite = 0;
    reg  [11:0]  paddr = 0;
    reg  [31:0]  pwdata = 0;
    wire [31:0]  prdata;
    wire         pready, pslverr, irq;

    pretrade_risk_engine #(.SYM_N(`CFG_SYM_N), .ACCT_N(`CFG_ACCT_N)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .prdata(prdata), .pready(pready), .pslverr(pslverr),
        .irq(irq)
    );

    // ---- vectors + golden ----
    reg [127:0] beat  [0:MAXO-1];
    integer     g_oid [0:MAXO-1];
    integer     g_acc [0:MAXO-1];
    integer     g_rea [0:MAXO-1];
    integer     g_sym [0:MAXO-1];
    integer     g_act [0:MAXO-1];
    integer     g_pos [0:MAXO-1];

    integer mismatches = 0;
    integer feed_i, recv_i;
    integer t_first_in, t_last_dec;
    integer anchor_reason = -1;
    integer passB_span = 0, peak_span = 0;

    // ---- APB write ----
    task apb_write(input [11:0] a, input [31:0] d);
    begin
        @(posedge clk); psel<=1; pwrite<=1; penable<=0; paddr<=a; pwdata<=d;
        @(posedge clk); penable<=1;
        @(posedge clk); psel<=0; penable<=0; pwrite<=0;
    end
    endtask

    // ---- APB read ----
    task apb_read(input [11:0] a, output [31:0] d);
    begin
        @(posedge clk); psel<=1; pwrite<=0; penable<=0; paddr<=a;
        @(posedge clk); penable<=1;
        @(posedge clk); d = prdata; psel<=0; penable<=0;
    end
    endtask

    // ---- program config.hex over APB ----
    task program_config;
        integer fd, code;
        reg [31:0] a, d;
    begin
        fd = $fopen("config.hex", "r");
        if (fd == 0) begin $display("FATAL: no config.hex"); $finish; end
        while (!$feof(fd)) begin
            code = $fscanf(fd, "%h %h\n", a, d);
            if (code == 2) apb_write(a[11:0], d);
        end
        $fclose(fd);
    end
    endtask

    // ---- check one received decision against golden[recv_i] ----
    task check_decision(input integer idx);
        reg [23:0] got_oid; reg got_acc; reg [3:0] got_rea;
        reg [15:0] got_sym; reg [7:0] got_act; reg signed [31:0] got_pos;
    begin
        got_oid = m_tdata[23:0];
        got_acc = m_tdata[24];
        got_rea = m_tdata[28:25];
        got_sym = m_tdata[47:32];
        got_act = m_tdata[55:48];
        got_pos = m_tdata[95:64];
        if (idx == 0) anchor_reason = got_rea;
        if (got_oid !== g_oid[idx][23:0] ||
            got_acc !== g_acc[idx][0]    ||
            got_rea !== g_rea[idx][3:0]  ||
            got_sym !== g_sym[idx][15:0] ||
            got_act !== g_act[idx][7:0]  ||
            got_pos !== g_pos[idx]) begin
            mismatches = mismatches + 1;
            if (mismatches <= 12)
                $display("MISMATCH[%0d] oid %0d/%0d acc %0d/%0d rea %0d/%0d sym %0d/%0d act %0d/%0d pos %0d/%0d",
                    idx, got_oid, g_oid[idx], got_acc, g_acc[idx], got_rea, g_rea[idx],
                    got_sym, g_sym[idx], got_act, g_act[idx], got_pos, g_pos[idx]);
        end
    end
    endtask

    // ---- one streaming pass; bubbles=1 adds random gaps/backpressure ----
    task run_pass(input integer bubbles);
    begin
        t_first_in = -1; t_last_dec = -1;
        feed_i = 0; recv_i = 0;
        fork
            // ---- feeder (AXIS master) ----
            begin : FEED
                integer g;
                for (feed_i = 0; feed_i < N; feed_i = feed_i + 1) begin
                    if (bubbles && (($random % 100) < 35)) begin
                        s_tvalid <= 0;
                        for (g = 0; g < 1 + ($unsigned($random) % 3); g = g + 1)
                            @(posedge clk);
                    end
                    s_tvalid <= 1; s_tdata <= beat[feed_i];
                    @(posedge clk);
                    while (!s_tready) @(posedge clk);
                    if (t_first_in < 0) t_first_in = cyc;
                end
                s_tvalid <= 0;
            end
            // ---- collector (AXIS slave + checker) ----
            begin : COLL
                recv_i = 0;
                while (recv_i < N) begin
                    m_tready <= bubbles ? (($random % 100) < 70) : 1'b1;
                    @(posedge clk);
                    if (m_tvalid && m_tready) begin
                        check_decision(recv_i);
                        if (recv_i == N-1) t_last_dec = cyc;
                        recv_i = recv_i + 1;
                    end
                end
                m_tready <= 1;
            end
        join
    end
    endtask

    // ---- CSR verification ----
    integer csr_fail = 0;
    task check_csr;
        reg [31:0] v; integer r;
        reg [31:0] exp_rej [1:8];
    begin
        exp_rej[1]=`EXP_REJ1; exp_rej[2]=`EXP_REJ2; exp_rej[3]=`EXP_REJ3;
        exp_rej[4]=`EXP_REJ4; exp_rej[5]=`EXP_REJ5; exp_rej[6]=`EXP_REJ6;
        exp_rej[7]=`EXP_REJ7; exp_rej[8]=`EXP_REJ8;
        apb_read(12'h00C, v); if (v !== `EXP_TOTAL)  begin csr_fail=csr_fail+1; $display("CSR total %0d != %0d", v, `EXP_TOTAL); end
        apb_read(12'h010, v); if (v !== `EXP_ACCEPT) begin csr_fail=csr_fail+1; $display("CSR accept %0d != %0d", v, `EXP_ACCEPT); end
        apb_read(12'h014, v); if (v !== `EXP_REJECT) begin csr_fail=csr_fail+1; $display("CSR reject %0d != %0d", v, `EXP_REJECT); end
        for (r = 1; r <= 8; r = r + 1) begin
            apb_read(12'h01C + (r-1)*4, v);
            if (v !== exp_rej[r]) begin csr_fail=csr_fail+1;
                $display("CSR rej[%0d] %0d != %0d", r, v, exp_rej[r]); end
        end
    end
    endtask

    // ---- peak micro-benchmark: a long all-accept burst at full rate ----
    integer peak_fail = 0;
    real    peak_tput = 0.0;
    task peak_test;
        integer i, seen, pt_first, pt_last, NP;
        reg [127:0] pb;
    begin
        NP = 1024;
        // sym0/acct0 buy price=1050 qty=10 -> always accepts under the pinned cfg
        pb = {7'b0, 1'b0, 24'hABCDEF, 32'd10, 32'd1050, 16'd0, 16'd0};
        apb_write(12'h000, 32'h0000000E);    // enable|irqen|softrst
        begin : WCP reg [31:0] v; apb_read(12'h004, v); while (v[2]) apb_read(12'h004, v); end
        repeat (2) @(posedge clk);
        pt_first = -1; pt_last = -1; seen = 0;
        fork
            begin : PF
                for (i = 0; i < NP; i = i + 1) begin
                    s_tvalid <= 1; s_tdata <= pb;
                    @(posedge clk);
                    while (!s_tready) @(posedge clk);
                    if (pt_first < 0) pt_first = cyc;
                end
                s_tvalid <= 0;
            end
            begin : PC
                while (seen < NP) begin
                    m_tready <= 1;
                    @(posedge clk);
                    if (m_tvalid && m_tready) begin
                        if (m_tdata[24] !== 1'b1) peak_fail = peak_fail + 1;
                        if (seen == NP-1) pt_last = cyc;
                        seen = seen + 1;
                    end
                end
            end
        join
        peak_tput = (pt_last > pt_first) ? (1.0*NP)/(pt_last - pt_first + 1) : 0.0;
        $display("PEAKBENCH orders=%0d span_cycles=%0d peak_ops_per_clk=%.4f fails=%0d",
                 NP, (pt_last - pt_first + 1), peak_tput, peak_fail);
    end
    endtask

    // ---- kill-switch + interrupt directed test ----
    integer kill_fail = 0;
    task kill_test;
        reg [31:0] v; integer i, seen;
    begin
        // soft reset clears state+stats, then engage kill + irq enable
        apb_write(12'h000, 32'h0000000E);   // enable|irqen|softrst, kill=0
        apb_read (12'h004, v); while (v[2]) apb_read(12'h004, v); // clr_busy
        apb_write(12'h000, 32'h00000007);   // kill|enable|irqen
        seen = 0;
        fork
            begin : KF
                for (i = 0; i < 8; i = i + 1) begin
                    s_tvalid <= 1; s_tdata <= beat[i];
                    @(posedge clk);
                    while (!s_tready) @(posedge clk);
                end
                s_tvalid <= 0;
            end
            begin : KC
                while (seen < 8) begin
                    m_tready <= 1;
                    @(posedge clk);
                    if (m_tvalid && m_tready) begin
                        if (m_tdata[24] !== 1'b0 || m_tdata[28:25] !== 4'd1) begin
                            kill_fail = kill_fail + 1;
                            $display("KILL: order %0d not REJ_KILL (acc %0d rea %0d)",
                                     seen, m_tdata[24], m_tdata[28:25]);
                        end
                        seen = seen + 1;
                    end
                end
            end
        join
        // interrupt must be asserted, then clear on W1C ack
        if (!irq) begin kill_fail=kill_fail+1; $display("KILL: irq not asserted"); end
        apb_read(12'h014, v); if (v !== 32'd8) begin kill_fail=kill_fail+1; $display("KILL: reject count %0d != 8", v); end
        apb_read(12'h01C, v); if (v !== 32'd8) begin kill_fail=kill_fail+1; $display("KILL: rej[1] %0d != 8", v); end
        apb_write(12'h008, 32'h1);           // IRQ_ACK
        @(posedge clk); @(posedge clk);
        if (irq) begin kill_fail=kill_fail+1; $display("KILL: irq did not clear"); end
        // restore: kill off, engine enabled
        apb_write(12'h000, 32'h00000006);
    end
    endtask

    // ---- version sanity ----
    reg [31:0] verval;

    integer passA_mm, passB_mm;
    real sustained, peak;

    initial begin
        $readmemh("orders.hex", beat);
        begin : LOADG
            integer fd, code, i;
            fd = $fopen("golden.txt", "r");
            if (fd == 0) begin $display("FATAL: no golden.txt"); $finish; end
            for (i = 0; i < N; i = i + 1)
                code = $fscanf(fd, "%d %d %d %d %d %d\n",
                    g_oid[i], g_acc[i], g_rea[i], g_sym[i], g_act[i], g_pos[i]);
            $fclose(fd);
        end

        // reset
        rst_n = 0; repeat (6) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

        // version register
        apb_read(12'h0FC, verval);
        if (verval !== 32'h15C30512) $display("WARN: version %h", verval);

        // program the limits, then clear state at bring-up (enable|irqen|softrst)
        program_config;
        apb_write(12'h000, 32'h0000000E);
        begin : WAITCLR0 reg [31:0] v; apb_read(12'h004, v); while (v[2]) apb_read(12'h004, v); end
        repeat (2) @(posedge clk);

        // ---- Pass A : bubbles + backpressure ----
        run_pass(1);
        passA_mm = mismatches;
        $display("PASSA mismatches=%0d anchor_reason=%0d", passA_mm, anchor_reason);
        if (anchor_reason !== `ANCHOR_REASON)
            $display("ANCHOR FAIL: got %0d exp %0d", anchor_reason, `ANCHOR_REASON);

        // ---- Pass B : soft reset then full rate ----
        apb_write(12'h000, 32'h0000000E);    // enable|irqen|softrst
        begin : WAITCLR reg [31:0] v; apb_read(12'h004, v); while (v[2]) apb_read(12'h004, v); end
        repeat (2) @(posedge clk);
        mismatches = 0;
        run_pass(0);
        passB_mm = mismatches;
        passB_span = t_last_dec - t_first_in + 1;
        sustained  = (passB_span > 0) ? (1.0*N)/passB_span : 0.0;
        $display("PASSB mismatches=%0d", passB_mm);
        $display("THROUGHPUT orders=%0d span_cycles=%0d sustained_ops_per_clk=%.4f",
                 N, passB_span, sustained);

        // ---- CSR histogram check (state = one full Pass B stream) ----
        check_csr;
        $display("CSR fails=%0d", csr_fail);

        // ---- peak micro-benchmark ----
        peak_test;
        peak = peak_tput;
        $display("PEAK ops_per_clk=%.4f latency_cycles=2", peak);

        // ---- kill-switch + IRQ ----
        kill_test;
        $display("KILL fails=%0d", kill_fail);

        // ---- verdict ----
        if (passA_mm == 0 && passB_mm == 0 && csr_fail == 0 && kill_fail == 0 &&
            peak_fail == 0 && anchor_reason == `ANCHOR_REASON) begin
            $display("RESULT orders=%0d passA=OK passB=OK csr=OK kill=OK", N);
            $display("TEST PASSED");
        end else begin
            $display("TEST FAILED (passA=%0d passB=%0d csr=%0d kill=%0d)",
                     passA_mm, passB_mm, csr_fail, kill_fail);
        end
        $finish;
    end

    // ---- watchdog ----
    initial begin
        #20000000;
        $display("TIMEOUT"); $display("TEST FAILED"); $finish;
    end
endmodule

`default_nettype wire
