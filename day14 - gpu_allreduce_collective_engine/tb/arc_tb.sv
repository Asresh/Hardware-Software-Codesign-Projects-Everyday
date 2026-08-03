// ============================================================================
// arc_tb.sv - differential testbench for the all-reduce collective engine.
//
//   1. Program : soft-reset, scratch/version/params read-back sanity.
//   2. Pass A  : run the whole descriptor ring under randomised memory wait
//                states (mem_ready dropped ~25%); check every destination word
//                against golden.txt.
//   3. Pass B  : reload the image, run at full rate, re-check, and measure the
//                sustained span (first gather -> last scatter).
//   4. Peak    : reload, run descriptor 0 alone (the big collective) at full
//                rate; measure latency and peak words/clock.
//   5. CSR     : completed / groups / words counters match the golden totals.
//   6. IRQ     : a zero-length descriptor raises the sticky error interrupt
//                with errcode==2; W1C clears it.
//
//   Zero mismatches across every pass is the pass condition.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
`include "arc_const.vh"

module arc_tb;
    localparam integer R      = `CFG_R;
    localparam integer P      = `CFG_P;
    localparam integer DW     = `CFG_DW;
    localparam integer AW     = 24;
    localparam integer DESC_W = `CFG_DESC_W;
    localparam integer ND     = `NUM_DESC;
    localparam integer NG     = `NUM_GOLDEN;
    localparam integer MEMW    = `MEM_WORDS;
    localparam integer MEM_TOTAL = MEMW + DESC_W + P + 8;
    localparam integer ERRB   = MEMW;              // crafted error descriptor base

    localparam [2:0] STATUS_DONE = 3'b001, STATUS_ERR = 3'b010, STATUS_BUSY = 3'b100;
    localparam [2:0] CTRL_START = 3'b001, CTRL_SRESET = 3'b010, CTRL_IRQEN = 3'b100;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---- DUT bus / master signals ----
    reg         reg_wr = 0, reg_rd = 0;
    reg  [7:0]  reg_addr = 0;
    reg  [31:0] reg_wdata = 0;
    wire [31:0] reg_rdata;

    wire              desc_rd_en;
    wire [AW-1:0]     desc_rd_addr;
    reg  [DESC_W*32-1:0] desc_rd_data;
    wire              src_rd_en;
    wire [R*AW-1:0]   src_rd_addr;
    reg  [R*P*DW-1:0] src_rd_data;
    wire              res_wr_en;
    wire [AW-1:0]     res_wr_addr;
    wire [P-1:0]      res_wr_mask;
    wire [P*DW-1:0]   res_wr_data;
    reg               mem_ready = 1;
    wire              irq;

    arc_collective_top #(.R(R), .P(P), .DW(DW), .AW(AW), .DESC_W(DESC_W)) dut (
        .clk(clk), .rst_n(rst_n),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr),
        .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .desc_rd_en(desc_rd_en), .desc_rd_addr(desc_rd_addr), .desc_rd_data(desc_rd_data),
        .src_rd_en(src_rd_en), .src_rd_addr(src_rd_addr), .src_rd_data(src_rd_data),
        .res_wr_en(res_wr_en), .res_wr_addr(res_wr_addr),
        .res_wr_mask(res_wr_mask), .res_wr_data(res_wr_data),
        .mem_ready(mem_ready), .irq(irq)
    );

    // ---- behavioural memory model ----
    reg [31:0] mem [0:MEM_TOTAL-1];
    integer mi, mr, mp;
    reg [AW-1:0] gbase;

    // descriptor read (whole 16-word descriptor, combinational)
    always @* begin
        for (mi = 0; mi < DESC_W; mi = mi + 1)
            desc_rd_data[mi*32 +: 32] = mem[desc_rd_addr + mi];
    end
    // source gather read (R x P words, combinational)
    always @* begin
        for (mr = 0; mr < R; mr = mr + 1) begin
            gbase = src_rd_addr[mr*AW +: AW];
            for (mp = 0; mp < P; mp = mp + 1)
                src_rd_data[(mr*P + mp)*32 +: 32] = mem[gbase + mp];
        end
    end
    // result scatter write (masked)
    integer wp;
    always @(posedge clk) begin
        if (res_wr_en) begin
            for (wp = 0; wp < P; wp = wp + 1)
                if (res_wr_mask[wp]) mem[res_wr_addr + wp] <= res_wr_data[wp*32 +: 32];
        end
    end

    // ---- golden ----
    integer g_addr [0:NG-1];
    reg [31:0] g_val [0:NG-1];

    task load_mem;
    begin
        $readmemh("mem_init.hex", mem, 0, MEMW-1);
    end
    endtask

    task load_golden;
        integer fd, r, k;
    begin
        fd = $fopen("golden.txt", "r");
        if (fd == 0) begin $display("cannot open golden.txt"); $finish; end
        for (k = 0; k < NG; k = k + 1) begin
            r = $fscanf(fd, "%d %h\n", g_addr[k], g_val[k]);
            if (r != 2) begin $display("golden parse error at %0d (r=%0d)", k, r); $finish; end
        end
        $fclose(fd);
    end
    endtask

    // ---- MMIO helpers (negedge-aligned) ----
    task reg_write(input [7:0] a, input [31:0] v);
    begin
        @(negedge clk);
        reg_addr = a; reg_wdata = v; reg_wr = 1;
        @(negedge clk);
        reg_wr = 0;
    end
    endtask

    task reg_read(input [7:0] a, output [31:0] v);
    begin
        @(negedge clk);
        reg_addr = a; reg_rd = 1;
        #1 v = reg_rdata;
        @(negedge clk);
        reg_rd = 0;
    end
    endtask

    // ---- measurement (per-pass) ----
    integer meas_en = 0;
    integer first_in, first_out, last_out;
    always @(posedge clk) begin
        if (meas_en) begin
            if (src_rd_en && first_in  < 0) first_in  = cyc;
            if (res_wr_en) begin
                if (first_out < 0) first_out = cyc;
                last_out = cyc;
            end
        end
    end

    // ---- run one collective ring; poll until done/err sticky is set ----
    task launch(input [AW-1:0] base, input [15:0] count, input integer irq_en, input integer measure);
        reg [31:0] st;
    begin
        reg_write(8'h00, {29'd0, CTRL_SRESET});     // clear counters + sticky
        reg_write(8'h08, {8'd0, base});             // DESC_BASE
        reg_write(8'h0C, {16'd0, count});           // DESC_COUNT
        reg_write(8'h1C, 32'hC0DE_5EED);            // SCRATCH bus sanity
        first_in = -1; first_out = -1; last_out = -1;
        meas_en = measure;
        reg_write(8'h00, {29'd0, (irq_en ? (CTRL_START|CTRL_IRQEN) : CTRL_START)});
        st = 0;
        while (!(st & (STATUS_DONE | STATUS_ERR))) reg_read(8'h04, st);
        meas_en = 0;
    end
    endtask

    // ---- check golden over [lo, hi) ----
    integer mism;
    task check_range(input integer lo, input integer hi);
        integer k;
    begin
        for (k = lo; k < hi; k = k + 1)
            if (mem[g_addr[k]] !== g_val[k]) begin
                mism = mism + 1;
                if (mism <= 10)
                    $display("  MISMATCH golden[%0d] addr=%0d got=%08x exp=%08x",
                             k, g_addr[k], mem[g_addr[k]], g_val[k]);
            end
    end
    endtask

    // ---- randomised memory wait-state generator (Pass A) ----
    integer stall_en = 0;
    always @(posedge clk) begin
        if (stall_en) mem_ready <= (($random % 4) != 0);   // ~25% not-ready
        else          mem_ready <= 1'b1;
    end

    // ---- main ----
    integer csr_fails = 0, irq_fails = 0, total_mism = 0;
    reg [31:0] rv;
    real sustained, peak_ops;
    integer span_full, peak_span, latency;

    initial begin
        load_mem;
        load_golden;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- control-plane sanity ----
        reg_write(8'h1C, 32'hC0DE_5EED);
        reg_read (8'h1C, rv); if (rv !== 32'hC0DE5EED)            csr_fails = csr_fails + 1;
        reg_read (8'h24, rv); if (rv !== 32'hFEED_000E)           csr_fails = csr_fails + 1;
        reg_read (8'h20, rv); if (rv[7:0] !== R || rv[15:8] !== P) csr_fails = csr_fails + 1;

        // ---- Pass A : wait states ----
        stall_en = 1;
        mism = 0;
        launch(24'd0, ND[15:0], 1, 0);
        stall_en = 0;
        @(posedge clk);
        check_range(0, NG);
        total_mism = total_mism + mism;
        $display("PASSA mismatches=%0d", mism);
        reg_read(8'h04, rv); if (!(rv & STATUS_DONE)) irq_fails = irq_fails + 1;
        if (irq !== 1'b1) irq_fails = irq_fails + 1;

        // ---- Pass B : full rate + measurement ----
        load_mem;
        mism = 0;
        launch(24'd0, ND[15:0], 1, 1);
        @(posedge clk);
        check_range(0, NG);
        total_mism = total_mism + mism;
        $display("PASSB mismatches=%0d", mism);

        span_full = last_out - first_in + 1;
        sustained = `EXP_WORDS * 1.0 / span_full;
        $display("THROUGHPUT words=%0d span_cycles=%0d", `EXP_WORDS, span_full);
        $display("sustained_ops_per_clk=%.4f", sustained);

        // ---- CSR statistics ----
        reg_read(8'h10, rv); if (rv !== ND)          csr_fails = csr_fails + 1; // COMPLETED
        reg_read(8'h14, rv); if (rv !== `EXP_GROUPS) csr_fails = csr_fails + 1; // GROUPS
        reg_read(8'h18, rv); if (rv !== `EXP_WORDS)  csr_fails = csr_fails + 1; // WORDS
        $display("CSR fails=%0d (completed=%0d groups=%0d words=%0d)",
                 csr_fails, ND, `EXP_GROUPS, `EXP_WORDS);

        // ---- Peak : descriptor 0 alone ----
        load_mem;
        mism = 0;
        launch(24'd0, 16'd1, 0, 1);
        @(posedge clk);
        check_range(0, `PEAK_GOLDEN);
        total_mism = total_mism + mism;
        latency   = first_out - first_in;
        peak_span = last_out - first_in + 1;
        peak_ops  = `PEAK_N * 1.0 / peak_span;
        $display("PEAK mismatches=%0d", mism);
        $display("LATENCY cycles=%0d", latency);
        $display("PEAKBENCH words=%0d span_cycles=%0d", `PEAK_N, peak_span);
        $display("peak_ops_per_clk=%.4f", peak_ops);

        // ---- IRQ / error : zero-length descriptor ----
        mem[ERRB + 0] = 32'h0000_0100;    // valid=1, op=SUM, but n=0 -> ZERON
        mem[ERRB + 1] = 32'd0;
        mem[ERRB + 2] = 32'd0;
        launch(ERRB[AW-1:0], 16'd1, 1, 0);
        reg_read(8'h04, rv); if (!(rv & STATUS_ERR)) irq_fails = irq_fails + 1;
        reg_read(8'h28, rv); if (rv !== 32'd2)       irq_fails = irq_fails + 1;  // ERR_ZERON
        if (irq !== 1'b1) irq_fails = irq_fails + 1;
        reg_write(8'h04, 32'h3);          // W1C clear both sticky bits
        reg_read(8'h04, rv); if (rv & (STATUS_DONE|STATUS_ERR)) irq_fails = irq_fails + 1;
        if (irq !== 1'b0) irq_fails = irq_fails + 1;
        $display("IRQ fails=%0d", irq_fails);

        // ---- verdict ----
        if (total_mism == 0 && csr_fails == 0 && irq_fails == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

    // watchdog
    initial begin
        #20000000;
        $display("TIMEOUT - TEST FAILED");
        $finish;
    end
endmodule

`default_nettype wire
