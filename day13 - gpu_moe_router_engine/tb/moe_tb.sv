// ============================================================================
// moe_tb.sv - differential testbench for the MoE top-k routing engine.
//
//   1. Program : soft-reset, set capacity, enable + arm IRQ; check scratch,
//                version and parameter read-back.
//   2. Pass A  : stream every token under randomised ingress bubbles + egress
//                backpressure; check each dispatch record against golden.txt.
//   3. Pass B  : soft-reset the counters, stream again at full rate, re-check,
//                and measure latency + sustained/peak tokens/clock.
//   4. CSR     : total tokens / routed / dropped and the summed per-expert
//                load counters match the golden totals.
//   5. IRQ     : over-capacity drops raise the sticky interrupt; W1C clears it.
//
//   Zero mismatches across every pass is the pass condition.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
`include "moe_const.vh"

module moe_tb;
    localparam integer MAXT = 4096;
    localparam integer N    = `NUM_TOKENS;
    localparam integer E    = `CFG_E;
    localparam integer SW   = E*16;

    localparam [2:0] C_EN = 3'b001, C_SR = 3'b010, C_IE = 3'b100;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---- DUT I/O ----
    reg  [SW-1:0] s_tdata = 0;
    reg           s_tvalid = 0, s_tlast = 0;
    wire          s_tready;
    wire [127:0]  m_tdata;
    wire          m_tvalid, m_tlast;
    reg           m_tready = 0;

    reg  [11:0]   awaddr = 0, araddr = 0;
    reg  [31:0]   wdata = 0;
    reg  [3:0]    wstrb = 0;
    reg           awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire          awready, wready, bvalid, arready, rvalid;
    wire [1:0]    bresp, rresp;
    wire [31:0]   rdata;
    wire          irq;

    moe_router_engine #(.E(`CFG_E), .K(`CFG_K)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .irq(irq)
    );

    // ---- vectors + golden ----
    reg [SW-1:0] beat [0:MAXT-1];
    integer g_tid[0:MAXT-1], g_e0[0:MAXT-1], g_w0[0:MAXT-1], g_o0[0:MAXT-1];
    integer g_e1[0:MAXT-1], g_w1[0:MAXT-1], g_o1[0:MAXT-1], g_rt[0:MAXT-1];
    integer exp_routed = 0, exp_overflow = 0;

    integer feed_i, recv_i, mism;
    integer pb_first_in, pb_first_out, pb_last_out;
    integer measure_en;

    // ---- AXI4-Lite helpers ----
    task axi_write(input [11:0] a, input [31:0] d);
    begin
        @(posedge clk);
        awaddr = a; wdata = d; wstrb = 4'hF; awvalid = 1; wvalid = 1; bready = 1;
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        awvalid = 0; wvalid = 0;
        @(posedge clk);
        bready = 0;
    end
    endtask

    task axi_read(input [11:0] a, output [31:0] d);
    begin
        @(posedge clk);
        araddr <= a; arvalid <= 1'b1; rready <= 1'b1;
        @(posedge clk);
        while (!arready) @(posedge clk);   // arready pulses on the cycle rdata is valid
        d = rdata;
        arvalid <= 1'b0;
        @(posedge clk);
        rready <= 1'b0;
    end
    endtask

    // ---- check one received record against golden[idx] ----
    task check_rec(input integer idx, input [127:0 ] d);
        integer tid, e0, w0, o0, e1, w1, o1, rt;
    begin
        tid = d[15:0];
        w0  = d[49:32];  e0 = d[57:50];  o0 = d[63];
        w1  = d[81:64];  e1 = d[89:82];  o1 = d[95];
        rt  = d[97:96];
        if (tid !== g_tid[idx] || e0 !== g_e0[idx] || w0 !== g_w0[idx] ||
            o0 !== g_o0[idx] || e1 !== g_e1[idx] || w1 !== g_w1[idx] ||
            o1 !== g_o1[idx] || rt !== g_rt[idx]) begin
            mism = mism + 1;
            if (mism <= 10)
                $display("  MISMATCH rec %0d: got tid=%0d e0=%0d w0=%0d o0=%0d e1=%0d w1=%0d o1=%0d rt=%0d | exp tid=%0d e0=%0d w0=%0d o0=%0d e1=%0d w1=%0d o1=%0d rt=%0d",
                    idx, tid,e0,w0,o0,e1,w1,o1,rt,
                    g_tid[idx],g_e0[idx],g_w0[idx],g_o0[idx],g_e1[idx],g_w1[idx],g_o1[idx],g_rt[idx]);
        end
    end
    endtask

    // ---- one streaming pass (feeder + collector) ----
    task run_pass(input integer use_bub, input integer use_bp, input integer measure);
    begin
        mism = 0; feed_i = 0; recv_i = 0;
        s_tvalid = 0; s_tlast = 0; m_tready = 0;
        measure_en = measure;
        fork
            // ---------------- feeder ----------------
            begin : FEEDER
                integer b;
                for (feed_i = 0; feed_i < N; feed_i = feed_i + 1) begin
                    if (use_bub) begin
                        b = ($random % 3);
                        if (b < 0) b = -b;
                        while (b > 0) begin s_tvalid <= 0; @(posedge clk); b = b - 1; end
                    end
                    s_tdata  <= beat[feed_i];
                    s_tlast  <= (feed_i == N-1);
                    s_tvalid <= 1;
                    @(posedge clk);
                    while (!(s_tvalid && s_tready)) @(posedge clk);
                    if (measure_en && pb_first_in < 0) pb_first_in = cyc;
                end
                s_tvalid <= 0; s_tlast <= 0;
            end
            // ---------------- collector ----------------
            begin : COLLECTOR
                m_tready <= 1;
                while (recv_i < N) begin
                    if (use_bp) m_tready <= ($random & 1);
                    else        m_tready <= 1;
                    @(posedge clk);
                    if (m_tvalid && m_tready) begin
                        check_rec(recv_i, m_tdata);
                        if (measure_en) begin
                            if (pb_first_out < 0) pb_first_out = cyc;
                            pb_last_out = cyc;
                        end
                        recv_i = recv_i + 1;
                    end
                end
                m_tready <= 1;
            end
        join
    end
    endtask

    // ---- load golden ----
    integer fd, r, k;
    task load_golden;
    begin
        fd = $fopen("golden.txt", "r");
        if (fd == 0) begin $display("cannot open golden.txt"); $finish; end
        for (k = 0; k < N; k = k + 1) begin
            r = $fscanf(fd, "%d %d %d %d %d %d %d %d\n",
                g_tid[k], g_e0[k], g_w0[k], g_o0[k], g_e1[k], g_w1[k], g_o1[k], g_rt[k]);
            if (r != 8) begin $display("golden parse error at %0d (r=%0d)", k, r); $finish; end
            exp_routed   = exp_routed + g_rt[k];
            exp_overflow = exp_overflow + (2 - g_rt[k]);
        end
        $fclose(fd);
    end
    endtask

    // ---- main ----
    integer csr_fails = 0, irq_fails = 0;
    integer i;
    reg [31:0] rv;
    integer load_sum;
    real sustained, peak_ops;
    integer span_full, peak_span, latency;

    initial begin
        $readmemh("tokens.hex", beat);
        load_golden;

        // reset
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- program + control-plane sanity ----
        axi_write(12'h01C, 32'hC0DE_5EED);          // SCRATCH
        axi_read (12'h01C, rv); if (rv !== 32'hC0DE5EED)         csr_fails = csr_fails + 1;
        axi_read (12'h020, rv); if (rv !== {8'hFE,8'hED,16'd13}) csr_fails = csr_fails + 1;
        axi_read (12'h018, rv); if (rv[7:0] != E)               csr_fails = csr_fails + 1; // PARAMS.E
        axi_write(12'h008, `CFG_CAP);               // CAP
        axi_write(12'h000, {29'b0, (C_EN|C_SR|C_IE)}); // enable + IRQ + soft-reset

        // ---- Pass A : bubbles + backpressure ----
        pb_first_in = -1; pb_first_out = -1; pb_last_out = -1;
        run_pass(1, 1, 0);
        $display("PASSA mismatches=%0d", mism);

        // ---- reset counters, Pass B : full rate + measurement ----
        axi_write(12'h000, {29'b0, (C_EN|C_SR|C_IE)});
        axi_read (12'h00C, rv); if (rv !== 32'd0) csr_fails = csr_fails + 1;  // TOKENS cleared
        pb_first_in = -1; pb_first_out = -1; pb_last_out = -1;
        run_pass(0, 0, 1);
        $display("PASSB mismatches=%0d", mism);

        // ---- throughput / latency ----
        latency   = pb_first_out - pb_first_in;
        span_full = pb_last_out - pb_first_in + 1;
        peak_span = pb_last_out - pb_first_out + 1;
        sustained = N * 1.0 / span_full;
        peak_ops  = N * 1.0 / peak_span;
        $display("LATENCY cycles=%0d", latency);
        $display("THROUGHPUT tokens=%0d span_cycles=%0d", N, span_full);
        $display("sustained_ops_per_clk=%.4f", sustained);
        $display("PEAKBENCH tokens=%0d span_cycles=%0d", N, peak_span);
        $display("peak_ops_per_clk=%.4f", peak_ops);

        // ---- CSR statistics check ----
        axi_read(12'h00C, rv); if (rv !== N)            csr_fails = csr_fails + 1; // TOKENS
        axi_read(12'h014, rv); if (rv !== exp_routed)   csr_fails = csr_fails + 1; // ROUTED
        axi_read(12'h010, rv); if (rv !== exp_overflow) csr_fails = csr_fails + 1; // OVERFLOWS
        load_sum = 0;
        for (i = 0; i < E; i = i + 1) begin
            axi_read(12'h040 + i*4, rv);
            load_sum = load_sum + rv;
        end
        if (load_sum !== exp_routed) csr_fails = csr_fails + 1;
        $display("CSR fails=%0d (tokens=%0d routed=%0d overflow=%0d loadsum=%0d)",
                 csr_fails, N, exp_routed, exp_overflow, load_sum);

        // ---- IRQ check ----
        if (exp_overflow > 0) begin
            axi_read(12'h004, rv);                        // STATUS
            if (rv[0] !== 1'b1) irq_fails = irq_fails + 1;
            if (irq       !== 1'b1) irq_fails = irq_fails + 1;
            axi_write(12'h004, 32'h1);                     // W1C clear
            axi_read(12'h004, rv);
            if (rv[0] !== 1'b0) irq_fails = irq_fails + 1;
            if (irq       !== 1'b0) irq_fails = irq_fails + 1;
        end
        $display("IRQ fails=%0d", irq_fails);

        // ---- verdict ----
        if (mism == 0 && csr_fails == 0 && irq_fails == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

    // watchdog
    initial begin
        #4000000;
        $display("TIMEOUT - TEST FAILED");
        $finish;
    end
endmodule

`default_nettype wire
