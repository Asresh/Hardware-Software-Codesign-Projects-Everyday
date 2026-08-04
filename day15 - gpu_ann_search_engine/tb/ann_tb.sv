// ============================================================================
// ann_tb.sv - differential testbench for the ANN top-K search engine.
//
//   1. Program : reset, VERSION/STATUS read-back sanity.
//   2. Pass A  : run every search under randomised ingress bubbles (tvalid
//                dropped ~30%); check the top-K of each shard bit-exact vs
//                golden.txt (kvalid entries: score AND id).
//   3. Pass B  : re-run every search at full ingress rate, re-check, and sum
//                the hardware cycle span (REG_LAST_CYC) for the sustained rate.
//   4. Peak    : re-run search 0 (the large shard) at full rate; report its
//                latency and peak dimensions/clock.
//   5. CSR     : cumulative vectors/beats counters match the golden totals.
//   6. IRQ     : a truncated shard (TLAST inside a vector) raises the sticky
//                error interrupt with errcode==ERR_TRUNC; W1C clears it.
//
//   Zero mismatches across every pass is the pass condition.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
`include "ann_const.vh"

module ann_tb;
    localparam integer D      = `CFG_D;
    localparam integer P      = `CFG_P;
    localparam integer K      = `CFG_K;
    localparam integer CHUNKS = `CFG_CHUNKS;
    localparam integer NS     = `NUM_SEARCH;
    localparam integer NB     = `NUM_BEATS;
    localparam integer QW     = D/4;

    // register map (mirror of ann_reg.vh / ann.h)
    localparam [7:0] REG_CTRL=0, REG_STATUS=1, REG_NDB=2, REG_IRQ_ACK=3,
                     REG_VERSION=4, REG_STAT_VECS=5, REG_STAT_BEATS=6,
                     REG_LAST_CYC=7, REG_ERRCODE=8, REG_QUERY_BASE=32,
                     REG_SCORE_BASE=128, REG_ID_BASE=192;
    localparam [31:0] CTRL_START=32'h1, CTRL_IRQEN=32'h4, CTRL_METRIC=32'h100;
    localparam [31:0] EXP_VERSION = 32'h0015_0001;

    // ---- clock / reset ----
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---- DUT bus ----
    reg         reg_wr = 0, reg_rd = 0;
    reg  [7:0]  reg_addr = 0;
    reg  [31:0] reg_wdata = 0;
    wire [31:0] reg_rdata;
    reg         s_tvalid = 0, s_tlast = 0;
    reg  [P*8-1:0] s_tdata = 0;
    wire        s_tready, irq;

    ann_search_top #(.D(D), .P(P), .K(K)) dut (
        .clk(clk), .rst_n(rst_n),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr),
        .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tdata(s_tdata), .s_tlast(s_tlast),
        .irq(irq)
    );

    // ---- stimulus / golden storage ----
    reg [P*8-1:0] stream_mem [0:NB-1];
    integer  s_metric [0:NS-1];
    integer  s_n      [0:NS-1];
    integer  s_kvalid [0:NS-1];
    integer  s_off    [0:NS-1];
    reg [31:0] s_qword [0:NS-1][0:QW-1];
    reg [31:0] g_score [0:NS-1][0:K-1];
    integer    g_id    [0:NS-1][0:K-1];

    integer mismatch = 0, checks = 0;
    integer fullrate_cycles = 0, bubble_cycles = 0;
    integer total_beats = 0, total_vecs = 0;
    integer peak_cycles = 0, peak_beats = 0;

    // ---------------- load files ------------------
    task load_stream; begin
        $readmemh("stream.hex", stream_mem);
    end endtask

    task load_searches;
        integer fd, s, w, k, r, off;
        integer t_metric, t_n, t_kv, t_id;
        reg [31:0] t_word, t_score;
    begin
        fd = $fopen("searches.txt", "r");
        if (fd == 0) begin $display("cannot open searches.txt"); $finish; end
        off = 0;
        for (s = 0; s < NS; s = s + 1) begin
            r = $fscanf(fd, "%d %d %d\n", t_metric, t_n, t_kv);
            if (r != 3) begin $display("hdr parse err s=%0d r=%0d", s, r); $finish; end
            s_metric[s] = t_metric; s_n[s] = t_n; s_kvalid[s] = t_kv;
            for (w = 0; w < QW; w = w + 1) begin
                r = $fscanf(fd, "%h", t_word);
                s_qword[s][w] = t_word;
            end
            for (k = 0; k < K; k = k + 1) begin
                r = $fscanf(fd, "%h %d", t_score, t_id);
                g_score[s][k] = t_score;
                g_id[s][k]    = t_id;
            end
            s_off[s] = off;
            off = off + s_n[s]*CHUNKS;
        end
        $fclose(fd);
    end endtask

    // ---------------- register access ------------------
    task reg_write(input [7:0] a, input [31:0] d);
    begin
        @(negedge clk); reg_wr = 1; reg_addr = a; reg_wdata = d;
        @(negedge clk); reg_wr = 0;
    end endtask

    task reg_read(input [7:0] a, output [31:0] d);
    begin
        @(negedge clk); reg_rd = 1; reg_addr = a;
        #1 d = reg_rdata;
        @(negedge clk); reg_rd = 0;
    end endtask

    // ---------------- one search ------------------
    task run_search(input integer s, input integer bub, input integer measure);
        integer w, i, nb, base, k;
        reg [31:0] st, rs, rid;
        reg do_bub;
    begin
        for (w = 0; w < QW; w = w + 1)
            reg_write(REG_QUERY_BASE + w[7:0], s_qword[s][w]);
        reg_write(REG_NDB, s_n[s]);
        reg_write(REG_CTRL, CTRL_START | CTRL_IRQEN |
                            (s_metric[s] ? CTRL_METRIC : 32'h0));

        base = s_off[s];
        nb   = s_n[s]*CHUNKS;
        i = 0;
        while (i < nb) begin
            @(negedge clk);
            do_bub = bub && (($unsigned($random) % 100) < 30);
            if (do_bub) begin s_tvalid = 0; s_tlast = 0; end
            else begin
                s_tvalid = 1;
                s_tdata  = stream_mem[base + i];
                s_tlast  = (i == nb-1);
            end
            @(posedge clk);
            if (s_tvalid && s_tready) i = i + 1;
        end
        @(negedge clk); s_tvalid = 0; s_tlast = 0;

        // wait for completion
        st = 0;
        while ((st & 32'h1) == 0) reg_read(REG_STATUS, st);
        if (!irq) begin $display("[s=%0d] FAIL: irq not asserted", s); mismatch=mismatch+1; end

        // check top-K
        for (k = 0; k < s_kvalid[s]; k = k + 1) begin
            reg_read(REG_SCORE_BASE + k[7:0], rs);
            reg_read(REG_ID_BASE + k[7:0], rid);
            checks = checks + 1;
            if (rs !== g_score[s][k] || rid !== g_id[s][k][31:0]) begin
                mismatch = mismatch + 1;
                if (mismatch < 20)
                  $display("[s=%0d k=%0d] MISMATCH hw{%08x,%0d} exp{%08x,%0d}",
                           s, k, rs, rid, g_score[s][k], g_id[s][k]);
            end
        end

        // measure: 0=none, 1=accumulate into pass totals, 2=peak micro-bench only
        if (measure == 1) begin
            reg_read(REG_LAST_CYC, rs);
            if (bub) bubble_cycles = bubble_cycles + rs;
            else     fullrate_cycles = fullrate_cycles + rs;
        end else if (measure == 2) begin
            reg_read(REG_LAST_CYC, rs);
            peak_cycles = rs; peak_beats = nb;
        end
        reg_write(REG_IRQ_ACK, 32'h1);
    end endtask

    // ---------------- error / IRQ directed test ------------------
    task run_trunc_test;
        integer w;
        reg [31:0] st, ec;
    begin
        for (w = 0; w < QW; w = w + 1) reg_write(REG_QUERY_BASE + w[7:0], 32'h0);
        reg_write(REG_NDB, 2);
        reg_write(REG_CTRL, CTRL_START | CTRL_IRQEN);
        // send a single beat with TLAST -> ends inside a vector (CHUNKS>1)
        @(negedge clk); s_tvalid = 1; s_tdata = 64'hDEADBEEFCAFEBABE; s_tlast = 1;
        @(posedge clk); while (!(s_tvalid && s_tready)) @(posedge clk);
        @(negedge clk); s_tvalid = 0; s_tlast = 0;
        st = 0;
        while ((st & 32'h2) == 0) reg_read(REG_STATUS, st);   // wait ERR
        reg_read(REG_ERRCODE, ec);
        if (ec !== 32'd1)  begin $display("FAIL: errcode=%0d", ec); mismatch=mismatch+1; end
        if (!irq)          begin $display("FAIL: error irq"); mismatch=mismatch+1; end
        reg_write(REG_IRQ_ACK, 32'h1);
        reg_read(REG_STATUS, st);
        if (st & 32'h2)    begin $display("FAIL: ERR not cleared"); mismatch=mismatch+1; end
        if (irq)           begin $display("FAIL: irq not cleared"); mismatch=mismatch+1; end
        $display("  [trunc] error+IRQ raised (errcode=1) and W1C-cleared");
    end endtask

    // ---------------- main ------------------
    integer s;
    reg [31:0] rd;
    initial begin
        load_stream;
        load_searches;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // 1. program sanity
        reg_read(REG_VERSION, rd);
        if (rd !== EXP_VERSION) begin
            $display("FAIL: VERSION %08x != %08x", rd, EXP_VERSION);
            mismatch = mismatch + 1;
        end
        reg_read(REG_STATUS, rd);
        if (rd & 32'h4) begin $display("FAIL: busy after reset"); mismatch=mismatch+1; end

        // 2. Pass A - randomised ingress bubbles
        $display("== Pass A : %0d searches under ingress bubbles ==", NS);
        for (s = 0; s < NS; s = s + 1) run_search(s, 1, 1);

        // 3. Pass B - full rate, gather totals
        $display("== Pass B : %0d searches at full rate ==", NS);
        for (s = 0; s < NS; s = s + 1) run_search(s, 0, 1);

        // 4. Peak - re-run search 0 alone at full rate
        $display("== Peak : re-run search 0 at full rate ==");
        run_search(0, 0, 2);

        // 5. CSR statistics (cumulative over passA + passB + peak)
        for (s = 0; s < NS; s = s + 1) begin
            total_beats = total_beats + s_n[s]*CHUNKS;
            total_vecs  = total_vecs  + s_n[s];
        end
        begin : csr_chk
            integer exp_beats, exp_vecs;
            reg [31:0] hbe, hve;
            exp_beats = total_beats*2 + s_n[0]*CHUNKS;   // A + B + peak(search0)
            exp_vecs  = total_vecs*2  + s_n[0];
            reg_read(REG_STAT_BEATS, hbe);
            reg_read(REG_STAT_VECS,  hve);
            if (hbe !== exp_beats[31:0]) begin
                $display("FAIL: STAT_BEATS hw=%0d exp=%0d", hbe, exp_beats); mismatch=mismatch+1;
            end
            if (hve !== exp_vecs[31:0]) begin
                $display("FAIL: STAT_VECS hw=%0d exp=%0d", hve, exp_vecs); mismatch=mismatch+1;
            end
            $display("  [csr] vecs=%0d beats=%0d (match)", hve, hbe);
        end

        // 6. truncated-shard error / IRQ
        $display("== IRQ : truncated shard ==");
        run_trunc_test;

        // ---- report ----
        $display("METRIC total_searches %0d", NS);
        $display("METRIC results_checked %0d", checks);
        $display("METRIC total_beats %0d", total_beats);
        $display("METRIC total_vecs %0d", total_vecs);
        $display("METRIC fullrate_cycles %0d", fullrate_cycles);
        $display("METRIC bubble_cycles %0d", bubble_cycles);
        $display("METRIC peak_search_beats %0d", peak_beats);
        $display("METRIC peak_search_cycles %0d", peak_cycles);
        $display("METRIC dims_per_vec %0d", D);
        $display("METRIC lanes %0d", P);

        if (mismatch == 0) $display("TEST PASSED : 0 mismatches over %0d checks", checks);
        else               $display("TEST FAILED : %0d mismatches", mismatch);
        $finish;
    end

    // safety timeout
    initial begin
        #50_000_000;
        $display("TEST FAILED : timeout");
        $finish;
    end
endmodule

`default_nettype wire
