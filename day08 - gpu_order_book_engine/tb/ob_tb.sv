// ============================================================================
// ob_tb.sv - differential testbench for the CAM-based order-book engine.
//
// For every stream in the generated corpus: soft-reset the book, drive the
// normalised message beats into the AXI4-Stream ingress, and on every
// bbo_commit compare the engine's best-bid/offer against the golden record the
// software model produced for that message. Two passes:
//   A) correctness with randomised stream backpressure
//   B) performance with the stream held valid every cycle (measures the
//      sustained message-to-BBO cycle spans)
// Any field mismatch fails the run.
//
// Single-writer discipline: the concurrent monitor owns every counter it
// updates; the stimulus task only reads them.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module ob_tb;
`include "lob_const.vh"

    // ---- clock / reset ----
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- DUT I/O ----
    reg              s_tvalid;
    wire             s_tready;
    reg  [MSGW-1:0]  s_tdata;
    reg              s_tlast;
    reg  [7:0]       reg_addr;
    reg              reg_wr, reg_rd;
    reg  [31:0]      reg_wdata;
    wire [31:0]      reg_rdata;
    wire             irq;
    wire             bbo_commit, bbo_bid_valid, bbo_ask_valid;
    wire [PW-1:0]    bbo_bid_price, bbo_ask_price;
    wire [QW-1:0]    bbo_bid_qty, bbo_ask_qty;
    wire [31:0]      msg_count;
    wire             overflow_o;

    order_book_engine #(.PW(PW), .QW(QW), .N(N_LEVELS), .MSGW(MSGW)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tdata(s_tdata), .s_tlast(s_tlast),
        .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_rd(reg_rd),
        .reg_wdata(reg_wdata), .reg_rdata(reg_rdata), .irq(irq),
        .bbo_commit(bbo_commit),
        .bbo_bid_valid(bbo_bid_valid), .bbo_bid_price(bbo_bid_price), .bbo_bid_qty(bbo_bid_qty),
        .bbo_ask_valid(bbo_ask_valid), .bbo_ask_price(bbo_ask_price), .bbo_ask_qty(bbo_ask_qty),
        .msg_count(msg_count), .overflow_o(overflow_o)
    );

    // ---- corpus storage ----
    reg [31:0]     job_len   [0:N_STREAMS-1];
    reg [MSGW-1:0] msg_mem   [0:MAX_MSGS-1];
    reg [BBOW-1:0] gold_mem  [0:MAX_MSGS-1];

    // ---- register map ----
    localparam [7:0] REG_CTRL     = 8'h00;
    localparam [7:0] REG_MSGCOUNT = 8'h08;

    // ---- monitor-owned state ----
    integer commit_cnt, accept_cnt, mismatches, total_checks;
    reg [63:0] cyc, span_start, last_commit_cyc, latency_min;
    reg        checking, checking_d;

    // ---- task-owned state ----
    reg [63:0] hw_cycles_total;
    integer    overflow_streams_hw;
    reg [31:0] lcg;

    // pack the DUT BBO outputs into the 128-bit golden record layout
    function [BBOW-1:0] dut_pack;
        input dummy;
        reg [BBOW-1:0] p;
        begin
            p = {BBOW{1'b0}};
            p[0        +: QW] = bbo_bid_qty;
            p[QW       +: PW] = bbo_bid_price;
            p[QW+PW]          = bbo_bid_valid;
            p[64       +: QW] = bbo_ask_qty;
            p[64+QW    +: PW] = bbo_ask_price;
            p[64+QW+PW]       = bbo_ask_valid;
            dut_pack = p;
        end
    endfunction

    // ---- concurrent monitor: sole writer of the counters ----
    always @(posedge clk) begin
        cyc        <= cyc + 64'd1;
        checking_d <= checking;
        if (checking & ~checking_d) begin
            commit_cnt <= 0;
            accept_cnt <= 0;
        end else if (checking) begin
            if (s_tvalid & s_tready) begin
                if (accept_cnt == 0) span_start <= cyc;
                accept_cnt <= accept_cnt + 1;
            end
            if (bbo_commit) begin
                total_checks <= total_checks + 1;
                if (dut_pack(1'b0) !== gold_mem[commit_cnt]) begin
                    mismatches <= mismatches + 1;
                    if (mismatches < 12)
                        $display("  MISMATCH commit %0d: dut=%032x gold=%032x",
                                 commit_cnt, dut_pack(1'b0), gold_mem[commit_cnt]);
                end
                if (commit_cnt == 0 && (cyc - span_start) < latency_min)
                    latency_min <= (cyc - span_start);
                last_commit_cyc <= cyc;
                commit_cnt <= commit_cnt + 1;
            end
        end
    end

    // ---- MMIO helpers ----
    task reg_write(input [7:0] a, input [31:0] d);
        begin
            @(posedge clk);
            reg_addr <= a; reg_wdata <= d; reg_wr <= 1'b1;
            @(posedge clk);
            reg_wr <= 1'b0;
        end
    endtask

    task book_reset;
        begin
            reg_write(REG_CTRL, 32'h2);   // arm irq
            reg_write(REG_CTRL, 32'h3);   // soft reset (pulse) + irq enable
            @(posedge clk); @(posedge clk);
        end
    endtask

    // TB-local LCG for backpressure decisions
    function [31:0] lcg_next;
        input dummy;
        begin
            lcg = lcg * 32'd1664525 + 32'd1013904223;
            lcg_next = lcg;
        end
    endfunction

    // ---- run one stream ----
    integer si, k, gap, expect_n;
    task run_stream(input integer sidx, input integer backpressure);
        begin
            $readmemh($sformatf("tb/vectors/msgs_%03d.hex", sidx), msg_mem);
            $readmemh($sformatf("tb/vectors/bbo_%03d.hex",  sidx), gold_mem);
            expect_n = job_len[sidx];

            book_reset;
            checking = 1'b1;
            @(posedge clk);               // let the monitor zero its counters

            for (k = 0; k < expect_n; k = k + 1) begin
                if (backpressure && (lcg_next(1'b0) & 32'h3) == 0) begin
                    s_tvalid <= 1'b0;
                    gap = 1 + (lcg_next(1'b0) % 3);
                    repeat (gap) @(posedge clk);
                end
                s_tvalid <= 1'b1;
                s_tdata  <= msg_mem[k];
                s_tlast  <= (k == expect_n-1);
                @(posedge clk);
                while (!s_tready) @(posedge clk);   // honour DUT backpressure
            end
            s_tvalid <= 1'b0;
            s_tlast  <= 1'b0;

            while (commit_cnt < expect_n) @(posedge clk);   // drain
            @(posedge clk);

            if (!backpressure && expect_n > 0) begin
                hw_cycles_total = hw_cycles_total +
                                  (last_commit_cyc - span_start + 1);
                if (overflow_o) overflow_streams_hw = overflow_streams_hw + 1;
            end

            reg_addr = REG_MSGCOUNT; #1;
            if (reg_rdata !== expect_n[31:0]) begin
                $display("  MSGCOUNT mismatch stream %0d: dut=%0d exp=%0d",
                         sidx, reg_rdata, expect_n);
            end

            checking = 1'b0;
            @(posedge clk);
        end
    endtask

    // ---- main ----
    initial begin
        s_tvalid = 0; s_tdata = 0; s_tlast = 0;
        reg_addr = 0; reg_wr = 0; reg_rd = 0; reg_wdata = 0;
        commit_cnt = 0; accept_cnt = 0; mismatches = 0; total_checks = 0;
        cyc = 0; span_start = 0; last_commit_cyc = 0; latency_min = 64'hFFFF_FFFF;
        checking = 0; checking_d = 0;
        hw_cycles_total = 0; overflow_streams_hw = 0; lcg = 32'hC0FFEE01;

        $readmemh("tb/vectors/jobs.hex", job_len);

        repeat (6) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        for (si = 0; si < N_STREAMS; si = si + 1)   // Pass A: backpressure
            run_stream(si, 1);
        for (si = 0; si < N_STREAMS; si = si + 1)   // Pass B: full rate
            run_stream(si, 0);

        $display("");
        $display("JOBS %0d", N_STREAMS);
        $display("CHECKS %0d", total_checks);
        $display("MISMATCHES %0d", mismatches);
        $display("HW_CYCLES_TOTAL %0d", hw_cycles_total);
        $display("LATENCY_CYCLES %0d", latency_min);
        $display("OVERFLOW_STREAMS_HW %0d", overflow_streams_hw);
        $display("");
        if (mismatches == 0) $display("TEST PASSED");
        else                 $display("TEST FAILED  (%0d mismatches)", mismatches);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT");
        $display("TEST FAILED  (timeout)");
        $finish;
    end
endmodule
`default_nettype wire
