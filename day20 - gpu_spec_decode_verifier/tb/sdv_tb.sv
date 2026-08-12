// ============================================================================
// sdv_tb.sv - differential testbench for the draft-tree verification engine.
//
//   Pass A  every job run one at a time under randomised ingress bubbles and
//           randomised egress backpressure; every egress beat compared
//           word-for-word against the golden model.
//   Pass B  the same jobs streamed back to back at full rate with ingress and
//           egress running concurrently, so a job loads while the previous
//           one's result is still draining.  Same beats, same counters - the
//           result may not depend on link timing.
//   Pass C  the peak job on its own at full rate: cycles, nodes/clock and the
//           accepted-token rate through the walk.
//   Pass D  control plane: CAPS, VERSION, the register-map checksum against
//           sw/sdv.h, cumulative counters and the per-position acceptance
//           histogram against the model's totals, PSLVERR on an unmapped
//           address, IRQ masking and the write-1-to-clear acknowledge.
//   Pass E  soft reset, then a job afterwards to prove the engine recovers.
//
// The rejection cases and the post-fault recovery job are part of the job list
// itself, so they are exercised in every pass rather than in a special one.
// Zero mismatches across all of it is the pass condition.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
`include "sdv_const.vh"

module sdv_tb;
    localparam integer N   = `CFG_MAX_NODES;
    localparam integer D   = `CFG_MAX_DEPTH;
    localparam integer NJ  = `NUM_JOBS;
    localparam integer ND  = `NUM_DIRECTED;
    localparam integer NB  = `NUM_BEATS;
    localparam integer MO  = `MAX_OUT;
    localparam integer PJ  = `PEAK_JOB;
    localparam integer MJ  = `MIN_JOB;

    // register map (word index; APB byte address = index*4)
    localparam [11:0] A_CTRL=12'h000, A_STATUS=12'h004, A_TH_ABS=12'h008,
                      A_TH_REL=12'h00C, A_MAX_ACC=12'h010, A_IRQ=12'h014,
                      A_ERRCODE=12'h018, A_CAPS=12'h01C, A_VERSION=12'h020,
                      A_ST_JOBS=12'h024, A_ST_NODES=12'h028, A_ST_ACC=12'h02C,
                      A_ST_ERRJ=12'h030, A_ST_CLAMP=12'h034, A_ST_BUSY=12'h038,
                      A_ST_SRC=12'h03C, A_ST_BP=12'h040, A_ST_LASTCYC=12'h044,
                      A_ST_LASTACC=12'h048, A_CSUM=12'h04C, A_HIST=12'h080;

    localparam [31:0] CTRL_EN=32'h1, CTRL_IRQEN=32'h2,
                      CTRL_CLRSTAT=32'h100, CTRL_SRST=32'h200;

    // ---- clock / reset -----------------------------------------------------
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---- DUT ---------------------------------------------------------------
    reg          psel = 0, penable = 0, pwrite = 0;
    reg  [11:0]  paddr = 0;
    reg  [31:0]  pwdata = 0;
    wire [31:0]  prdata;
    wire         pready, pslverr;

    reg          s_tvalid = 0, s_tlast = 0;
    reg  [127:0] s_tdata = 0;
    wire         s_tready;

    wire         m_tvalid, m_tlast;
    wire [127:0] m_tdata;
    reg          m_tready = 0;
    wire         irq, fifo_ovf;

    sdv_top #(.MAX_NODES(N), .MAX_DEPTH(D)) dut (
        .clk(clk), .rst_n(rst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .prdata(prdata), .pready(pready), .pslverr(pslverr),
        .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tdata(s_tdata),
        .s_tlast(s_tlast),
        .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tdata(m_tdata),
        .m_tlast(m_tlast),
        .irq(irq), .dbg_fifo_ovf(fifo_ovf)
    );

    // ---- stimulus / golden storage -----------------------------------------
    reg [127:0] beats [0:NB-1];
    integer j_mode  [0:NJ-1];
    integer j_abs   [0:NJ-1];
    integer j_rel   [0:NJ-1];
    integer j_cap   [0:NJ-1];
    integer j_n     [0:NJ-1];
    integer j_out   [0:NJ-1];
    integer j_off   [0:NJ-1];
    reg [31:0] g_beat [0:NJ-1][0:MO-1][0:3];

    integer g_jobs, g_nodes, g_accept, g_errjobs, g_clamp;
    integer g_hist [0:D-1];

    integer mismatch = 0, checks = 0;
    integer pipe_cycles = 0, peak_cycles = 0, peak_acc = 0, min_cycles = 0;
    integer passA_cycles = 0;

    integer dbg_job = -1, dbg_beat = -1;

    task chk32(input [255:0] what, input [31:0] exp, input [31:0] got);
    begin
        checks = checks + 1;
        if (exp !== got) begin
            mismatch = mismatch + 1;
            $display("MISMATCH %0s (job %0d beat %0d): expected %08x got %08x",
                     what, dbg_job, dbg_beat, exp, got);
        end
    end
    endtask

    // ---- file loading ------------------------------------------------------
    task load_files;
        integer fd, i, b, w, r, off;
        integer t0, t1, t2, t3, t4, t5;
        reg [31:0] tw;
    begin
        $readmemh("stream.hex", beats);

        fd = $fopen("jobs.txt", "r");
        if (fd == 0) begin $display("cannot open jobs.txt"); $finish; end
        off = 0;
        for (i = 0; i < NJ; i = i + 1) begin
            r = $fscanf(fd, "%d %d %d %d %d %d\n", t0, t1, t2, t3, t4, t5);
            if (r != 6) begin $display("jobs.txt parse error at %0d", i); $finish; end
            j_mode[i] = t0; j_abs[i] = t1; j_rel[i] = t2; j_cap[i] = t3;
            j_n[i]    = t4; j_out[i] = t5; j_off[i] = off;
            off = off + t4;
            for (b = 0; b < j_out[i]; b = b + 1)
                for (w = 0; w < 4; w = w + 1) begin
                    r = $fscanf(fd, "%h", tw);
                    g_beat[i][b][w] = tw;
                end
        end
        $fclose(fd);

        fd = $fopen("totals.txt", "r");
        if (fd == 0) begin $display("cannot open totals.txt"); $finish; end
        r = $fscanf(fd, "%d %d %d %d %d\n", g_jobs, g_nodes, g_accept,
                    g_errjobs, g_clamp);
        if (r != 5) begin $display("totals.txt parse error"); $finish; end
        for (i = 0; i < D; i = i + 1) r = $fscanf(fd, "%d\n", g_hist[i]);
        $fclose(fd);
    end
    endtask

    // ---- APB3 --------------------------------------------------------------
    task apb_write(input [11:0] a, input [31:0] d);
    begin
        @(posedge clk);
        psel <= 1; pwrite <= 1; paddr <= a; pwdata <= d; penable <= 0;
        @(posedge clk);
        penable <= 1;
        @(posedge clk);
        while (!pready) @(posedge clk);
        psel <= 0; penable <= 0; pwrite <= 0;
    end
    endtask

    task apb_read(input [11:0] a, output [31:0] d, output err);
    begin
        @(posedge clk);
        psel <= 1; pwrite <= 0; paddr <= a; penable <= 0;
        @(posedge clk);
        penable <= 1;
        #1;
        d = prdata; err = pslverr;
        @(posedge clk);
        psel <= 0; penable <= 0;
    end
    endtask

    task apb_rd(input [11:0] a, output [31:0] d);
        reg e;
    begin
        apb_read(a, d, e);
    end
    endtask

    task program_job(input integer i);
        reg [31:0] c;
    begin
        apb_write(A_TH_ABS,  j_abs[i]);
        apb_write(A_TH_REL,  j_rel[i]);
        apb_write(A_MAX_ACC, j_cap[i]);
        c = CTRL_EN | CTRL_IRQEN | (j_mode[i] << 2);
        apb_write(A_CTRL, c);
    end
    endtask

    // ---- ingress driver ----------------------------------------------------
    // Both stream ports are sampled *at* the rising edge, in the active region,
    // so the values read are the ones the DUT itself registers on that edge.
    // Reading them after a delay would instead report the following cycle's
    // state: TREADY drops as the load ends and TDATA has already advanced, so a
    // late sample loses the first egress beat and re-offers the last ingress
    // one.  This is the one place the testbench has to be careful about the
    // difference between "the transfer that happened" and "what the wires say
    // afterwards".
    task send_job(input integer i, input integer bubbles);
        integer k;
        reg do_bub;
    begin
        k = 0;
        while (k < j_n[i]) begin
            do_bub = bubbles && (($unsigned($random) % 100) < 30);
            @(negedge clk);
            if (do_bub) begin
                s_tvalid <= 0;
            end else begin
                s_tvalid <= 1;
                s_tdata  <= beats[j_off[i] + k];
                s_tlast  <= (k == j_n[i] - 1);
            end
            @(posedge clk);
            if (s_tvalid && s_tready) k = k + 1;
        end
        @(negedge clk);
        s_tvalid <= 0; s_tlast <= 0;
    end
    endtask

    // ---- egress collector --------------------------------------------------
    task recv_job(input integer i, input integer bp);
        integer b;
        reg do_bp;
    begin
        b = 0;
        while (b < j_out[i]) begin
            do_bp = bp && (($unsigned($random) % 100) < 35);
            @(negedge clk);
            m_tready <= !do_bp;
            @(posedge clk);
            if (m_tvalid && m_tready) begin
                dbg_job = i; dbg_beat = b;
                chk32("beat.w0", g_beat[i][b][0], m_tdata[31:0]);
                chk32("beat.w1", g_beat[i][b][1], m_tdata[63:32]);
                chk32("beat.w2", g_beat[i][b][2], m_tdata[95:64]);
                chk32("beat.w3", g_beat[i][b][3], m_tdata[127:96]);
                checks = checks + 1;
                if (m_tlast !== (b == j_out[i] - 1)) begin
                    mismatch = mismatch + 1;
                    $display("MISMATCH job %0d beat %0d tlast=%b", i, b, m_tlast);
                end
                b = b + 1;
            end
        end
        @(negedge clk);
        m_tready <= 0;
    end
    endtask

    // ---- pass B: one process streams, another collects ---------------------
    integer pb_i, pb_k, pb_b, pb_job, pb_beat;
    integer pipe_start, pipe_end;

    task pass_pipelined;
    begin
        pipe_start = cyc;
        fork
            begin : ingress
                for (pb_i = 0; pb_i < NJ; pb_i = pb_i + 1) begin
                    program_job(pb_i);
                    send_job(pb_i, 0);
                end
            end
            begin : egress
                m_tready <= 1;
                pb_job = 0;
                while (pb_job < NJ) begin
                    pb_beat = 0;
                    while (pb_beat < j_out[pb_job]) begin
                        @(posedge clk);
                        if (m_tvalid && m_tready) begin
                            dbg_job = pb_job; dbg_beat = pb_beat;
                            chk32("pipe.w0", g_beat[pb_job][pb_beat][0], m_tdata[31:0]);
                            chk32("pipe.w1", g_beat[pb_job][pb_beat][1], m_tdata[63:32]);
                            chk32("pipe.w2", g_beat[pb_job][pb_beat][2], m_tdata[95:64]);
                            chk32("pipe.w3", g_beat[pb_job][pb_beat][3], m_tdata[127:96]);
                            checks = checks + 1;
                            if (m_tlast !== (pb_beat == j_out[pb_job] - 1)) begin
                                mismatch = mismatch + 1;
                                $display("MISMATCH pipe job %0d beat %0d tlast",
                                         pb_job, pb_beat);
                            end
                            pb_beat = pb_beat + 1;
                        end
                    end
                    pb_job = pb_job + 1;
                end
                pipe_end = cyc;
            end
        join
        m_tready <= 0;
        pipe_cycles = pipe_end - pipe_start;
    end
    endtask

    // ---- counter checks ----------------------------------------------------
    task check_counters;
        reg [31:0] v;
        integer i;
    begin
        apb_rd(A_ST_JOBS,  v); chk32("stat.jobs",    g_jobs,    v);
        apb_rd(A_ST_NODES, v); chk32("stat.nodes",   g_nodes,   v);
        apb_rd(A_ST_ACC,   v); chk32("stat.accept",  g_accept,  v);
        apb_rd(A_ST_ERRJ,  v); chk32("stat.errjobs", g_errjobs, v);
        apb_rd(A_ST_CLAMP, v); chk32("stat.clamp",   g_clamp,   v);
        for (i = 0; i < D; i = i + 1) begin
            dbg_beat = i;
            apb_rd(A_HIST + i*4, v);
            chk32("stat.hist", g_hist[i], v);
        end
        dbg_beat = -1;
    end
    endtask

    // ------------------------------------------------------------------------
    integer i, k;
    reg [31:0] v, exp_irq;
    reg        e;
    integer    a_start, a_end;
    real       r_nodes_clk, r_tok_clk, r_speedup;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("sdv.vcd");
            $dumpvars(0, sdv_tb);
        end

        load_files();

        repeat (4) @(posedge clk);
        rst_n <= 1;
        repeat (2) @(posedge clk);

        // ---- identity / caps ------------------------------------------------
        apb_rd(A_VERSION, v); chk32("VERSION", 32'h0020_0001, v);
        apb_rd(A_CAPS,    v); chk32("CAPS",    (D << 16) | N, v);
        apb_rd(A_CSUM,    v); chk32("REGMAP_CSUM", `REGMAP_CSUM, v);
        apb_rd(A_STATUS,  v); chk32("STATUS idle", 32'h2, v);

        // =====================================================================
        // Pass A - one job at a time, ingress bubbles + egress backpressure
        // =====================================================================
        apb_write(A_CTRL, CTRL_EN | CTRL_CLRSTAT);
        a_start = cyc;
        for (i = 0; i < NJ; i = i + 1) begin
            program_job(i);
            send_job(i, 1);
            recv_job(i, 1);
        end
        a_end = cyc;
        passA_cycles = a_end - a_start;
        $display("PASS A done: %0d jobs, %0d cycles, %0d checks, %0d mismatches",
                 NJ, passA_cycles, checks, mismatch);
        check_counters();
        apb_rd(A_ST_BUSY, v);
        $display("METRIC passA_busy_cycles %0d", v);

        // =====================================================================
        // Pass B - back to back at full rate, ingress and egress concurrent
        // =====================================================================
        apb_write(A_CTRL, CTRL_EN | CTRL_CLRSTAT);
        apb_write(A_IRQ, 32'h7);
        pass_pipelined();
        $display("PASS B done: %0d cycles for %0d jobs / %0d nodes",
                 pipe_cycles, NJ, g_nodes);
        check_counters();
        apb_rd(A_ST_BUSY, v); $display("METRIC busy_cycles %0d", v);
        apb_rd(A_ST_SRC,  v); $display("METRIC srcstall_cycles %0d", v);
        apb_rd(A_ST_BP,   v); $display("METRIC bpstall_cycles %0d", v);

        // =====================================================================
        // Pass C - the peak job on its own at full rate
        // =====================================================================
        apb_write(A_CTRL, CTRL_EN | CTRL_CLRSTAT);
        program_job(PJ);
        send_job(PJ, 0);
        recv_job(PJ, 0);
        apb_rd(A_ST_LASTCYC, v); peak_cycles = v;
        apb_rd(A_ST_LASTACC, v); peak_acc    = v;
        chk32("peak accepted", g_beat[PJ][j_out[PJ]-1][0], peak_acc);
        chk32("peak cycles model", j_n[PJ] + j_out[PJ] + 2, peak_cycles);
        $display("METRIC peak_nodes %0d", j_n[PJ]);
        $display("METRIC peak_cycles %0d", peak_cycles);
        $display("METRIC peak_accepted %0d", peak_acc);

        // the shortest job there is - a root with no children - measures the
        // fixed cost of a verification: one load beat, CHECK, one walk step
        // that finds nothing, TRAIL
        program_job(MJ);
        send_job(MJ, 0);
        recv_job(MJ, 0);
        apb_rd(A_ST_LASTCYC, v); min_cycles = v;
        chk32("min cycles model", j_n[MJ] + j_out[MJ] + 2, min_cycles);
        $display("METRIC min_cycles %0d", min_cycles);

        // =====================================================================
        // Pass D - control plane
        // =====================================================================
        // unmapped register answers with PSLVERR
        apb_read(12'h060, v, e);
        checks = checks + 1;
        if (e !== 1'b1) begin
            mismatch = mismatch + 1;
            $display("MISMATCH unmapped read did not raise PSLVERR");
        end
        apb_read(12'h1FC, v, e);
        checks = checks + 1;
        if (e !== 1'b1) begin
            mismatch = mismatch + 1;
            $display("MISMATCH unmapped hist read did not raise PSLVERR");
        end
        apb_read(A_VERSION, v, e);
        checks = checks + 1;
        if (e !== 1'b0) begin
            mismatch = mismatch + 1;
            $display("MISMATCH mapped read raised PSLVERR");
        end

        // IRQ: sticky, masked by CTRL[1], cleared W1C.
        // The expected mask is derived from the job's own golden trailer rather
        // than assumed to be DONE: job 0 is the peak chain, which runs into the
        // accepted-token cap, so CLAMP latches alongside DONE and the W1C has to
        // clear both before the line drops again.
        apb_write(A_IRQ, 32'h7);
        apb_write(A_CTRL, CTRL_EN);              // interrupt disabled
        program_job(0);
        apb_write(A_CTRL, CTRL_EN | (j_mode[0] << 2));
        send_job(0, 0);
        recv_job(0, 0);
        exp_irq = 32'h1
                | ((g_beat[0][j_out[0]-1][2] != 0)            ? 32'h2 : 32'h0)
                | ((g_beat[0][j_out[0]-1][3] & 32'h1) != 0    ? 32'h4 : 32'h0);
        checks = checks + 1;
        if (irq !== 1'b0) begin
            mismatch = mismatch + 1;
            $display("MISMATCH irq asserted while masked");
        end
        apb_rd(A_IRQ, v); chk32("irq sticky", exp_irq, v);
        apb_write(A_CTRL, CTRL_EN | CTRL_IRQEN);
        repeat (2) @(posedge clk);
        checks = checks + 1;
        if (irq !== 1'b1) begin
            mismatch = mismatch + 1;
            $display("MISMATCH irq did not assert once unmasked");
        end
        apb_write(A_IRQ, exp_irq);                // clear every bit that latched
        apb_rd(A_IRQ, v); chk32("irq after W1C", 32'h0, v);
        repeat (2) @(posedge clk);
        checks = checks + 1;
        if (irq !== 1'b0) begin
            mismatch = mismatch + 1;
            $display("MISMATCH irq still asserted after W1C");
        end

        // a rejection job sets the error interrupt and leaves the code behind
        for (i = 0; i < NJ; i = i + 1) begin
            if (g_beat[i][j_out[i]-1][2] != 0) begin
                apb_write(A_IRQ, 32'h7);
                program_job(i);
                send_job(i, 0);
                recv_job(i, 0);
                apb_rd(A_IRQ, v);
                chk32("err irq", 32'h3, v);
                apb_rd(A_ERRCODE, v);
                chk32("errcode", g_beat[i][j_out[i]-1][2], v);
                i = NJ;
            end
        end

        // =====================================================================
        // Pass E - soft reset, then a job to prove recovery
        // =====================================================================
        apb_write(A_CTRL, CTRL_EN | CTRL_SRST);
        repeat (4) @(posedge clk);
        apb_write(A_CTRL, CTRL_EN | CTRL_CLRSTAT);
        apb_rd(A_STATUS, v); chk32("STATUS after soft reset", 32'h2, v);
        program_job(ND - 1);
        send_job(ND - 1, 0);
        recv_job(ND - 1, 0);
        apb_rd(A_ST_JOBS, v); chk32("jobs after soft reset", 32'd1, v);

        // the result FIFO is sized so it can never overflow
        checks = checks + 1;
        if (fifo_ovf !== 1'b0) begin
            mismatch = mismatch + 1;
            $display("MISMATCH result FIFO overflowed");
        end

        // ---- report ----------------------------------------------------------
        r_nodes_clk = 1.0 * j_n[PJ] / peak_cycles;
        r_tok_clk   = 1.0 * peak_acc / (peak_acc + 1);
        $display("METRIC pipe_cycles %0d", pipe_cycles);
        $display("METRIC passA_cycles %0d", passA_cycles);
        $display("METRIC total_jobs %0d", NJ);
        $display("METRIC total_nodes %0d", g_nodes);
        $display("METRIC total_accept %0d", g_accept);
        $display("RESULT checks=%0d fails=%0d", checks, mismatch);
        if (mismatch == 0) $display("TEST PASSED");
        else               $display("TEST FAILED");
        $finish;
    end

    // ---- safety net --------------------------------------------------------
    initial begin
        #20000000;
        $display("TIMEOUT");
        $display("TEST FAILED");
        $finish;
    end
endmodule
`default_nettype wire
