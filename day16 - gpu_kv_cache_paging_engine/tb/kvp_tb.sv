// ============================================================================
// kvp_tb.sv - differential testbench for the KV-cache paging engine.
//
//   The testbench is the system around the engine: a Wishbone B4 slave holding
//   system memory (block table, request arrays, result arrays) with a
//   programmable number of wait states, plus the MMIO master that plays exactly
//   the register sequence in sw/kvp_driver.c.
//
//     1. Program  : VERSION read-back, reset state sanity.
//     2. Pass A   : run all batches with randomised memory wait states (0..3);
//                   after every batch check every result word in memory against
//                   golden_res.hex, the seven statistics CSRs, FREE_COUNT, the
//                   sticky out-of-memory bit and the interrupt; at the end check
//                   the whole block table against golden_bt.hex.
//     3. Pass B   : reload memory, re-run every batch at zero wait states,
//                   re-check everything, and sum LAST_CYC for the sustained
//                   rate; the peak batch (512 fully-cached translations) and the
//                   single-translation latency probe come from this pass.
//     4. Errors   : a poisoned block-table address (Wishbone ERR_I) and a slave
//                   that never acknowledges (master watchdog) must both raise the
//                   sticky bus-error bit + interrupt and end the run, and W1C
//                   must clear them.
//
//   Zero mismatches across both passes is the pass condition.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
`include "kvp_const.vh"

module kvp_tb;
    localparam integer NB       = `NUM_BATCH;
    localparam integer TOT_RES  = `TOT_RES;
    localparam integer MEMW     = `MEM_WORDS;
    localparam integer BTW      = `BT_WORDS;
    localparam integer PEAK_B   = `PEAK_BATCH;
    localparam integer LAT_B    = `LAT_BATCH;

    // ---- register map (mirror of rtl/kvp_defs.vh and sw/kvp.h) ----
    localparam [7:0] R_CTRL=0, R_STATUS=1, R_REQ_BASE=2, R_RES_BASE=3, R_REQ_COUNT=4,
                     R_BT_BASE=5, R_BT_STRIDE=6, R_FREE_PUSH=7, R_FREE_COUNT=8,
                     R_STAT_REQS=9, R_STAT_XLATES=10, R_STAT_HITS=11, R_STAT_MISSES=12,
                     R_STAT_ALLOCS=13, R_STAT_FREES=14, R_STAT_ERRS=15, R_LAST_CYC=16,
                     R_RES_WORDS=17, R_IRQ_ACK=18, R_VERSION=19;
    localparam [31:0] CTRL_START=32'h1, CTRL_SRST=32'h2, CTRL_IRQEN=32'h4;
    localparam [31:0] ST_BUSY=32'h1, ST_DONE=32'h2, ST_OOM=32'h4, ST_BUS=32'h8,
                      ST_IRQ=32'h10;
    localparam [31:0] EXP_VERSION = 32'h0016_0001;

    // ---- clock / reset ----
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- MMIO ----
    reg         reg_wr = 0, reg_rd = 0;
    reg  [7:0]  reg_addr = 0;
    reg  [31:0] reg_wdata = 0;
    wire [31:0] reg_rdata;
    wire        irq;

    // ---- Wishbone ----
    wire        wb_cyc, wb_stb, wb_we;
    wire [31:0] wb_adr, wb_dat_o;
    wire [3:0]  wb_sel;
    reg         wb_ack, wb_err;
    reg  [31:0] wb_dat_i;

    kvp_top #(
        .SETS(`CFG_SETS), .WAYS(`CFG_WAYS), .FREE_DEPTH(`CFG_FREE_DEPTH),
        .WB_TIMEOUT(256)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr),
        .reg_wdata(reg_wdata), .reg_rdata(reg_rdata), .irq(irq),
        .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb), .wb_we_o(wb_we),
        .wb_adr_o(wb_adr), .wb_dat_o(wb_dat_o), .wb_sel_o(wb_sel),
        .wb_ack_i(wb_ack), .wb_dat_i(wb_dat_i), .wb_err_i(wb_err)
    );

    // ================= Wishbone B4 slave: system memory =================
    reg [31:0] mem [0:MEMW-1];
    integer    wmax        = 0;              // max wait states (0 = full rate)
    reg [31:0] poison_addr = 32'hFFFF_FFFF;  // address that answers with ERR_I
    reg        hang        = 0;              // never acknowledge (watchdog test)
    integer    rseed       = 32'h0D16_5EED;

    wire        sel_i   = wb_cyc & wb_stb;
    wire [31:0] widx    = {2'b00, wb_adr[31:2]} & (MEMW-1);
    wire        poisonh = (poison_addr != 32'hFFFF_FFFF) && (wb_adr == poison_addr);
    reg  [3:0]  wl = 0;
    integer     xacts = 0, wait_cycles = 0;

    function integer next_wait;
        integer r;
        begin
            if (wmax <= 0) next_wait = 0;
            else begin
                r = $random(rseed);
                if (r < 0) r = -r;
                next_wait = r % (wmax + 1);
            end
        end
    endfunction

    always @(*) begin
        wb_ack   = sel_i && (wl == 0) && !hang && !poisonh;
        wb_err   = sel_i && poisonh;
        wb_dat_i = mem[widx];
    end

    always @(posedge clk) begin
        if (sel_i && wb_ack && wb_we) mem[widx] <= wb_dat_o;
        if (sel_i && wb_ack)          xacts <= xacts + 1;
        if (sel_i && !wb_ack && !wb_err) wait_cycles <= wait_cycles + 1;
        if (!sel_i)        wl <= next_wait();
        else if (wl != 0)  wl <= wl - 1;
        else               wl <= next_wait();
    end

    // ================= golden data =================
    reg [31:0] gres [0:TOT_RES-1];
    reg [31:0] gbt  [0:BTW-1];

    integer b_reset  [0:NB-1];
    integer b_nfree  [0:NB-1];
    integer b_reqw   [0:NB-1];
    integer b_resw   [0:NB-1];
    integer b_nreq   [0:NB-1];
    integer b_nres   [0:NB-1];
    integer b_dxl    [0:NB-1];
    integer b_creqs  [0:NB-1];
    integer b_cxl    [0:NB-1];
    integer b_chits  [0:NB-1];
    integer b_cmiss  [0:NB-1];
    integer b_calloc [0:NB-1];
    integer b_cfree  [0:NB-1];
    integer b_cerrs  [0:NB-1];
    integer b_cpool  [0:NB-1];
    integer b_oom    [0:NB-1];
    reg [31:0] b_seed [0:NB-1][0:`MAX_FREE_SEED-1];

    integer b_cycles [0:NB-1];

    integer mismatch = 0, checks = 0;
    integer pass_cycles = 0, bubble_cycles = 0;

    task load_batches;
        integer fd, i, j, r;
        reg [31:0] w;
    begin
        fd = $fopen("batches.txt", "r");
        if (fd == 0) begin $display("cannot open batches.txt"); $finish; end
        for (i = 0; i < NB; i = i + 1) begin
            r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                        b_reset[i], b_nfree[i], b_reqw[i], b_resw[i], b_nreq[i],
                        b_nres[i], b_dxl[i], b_creqs[i], b_cxl[i], b_chits[i],
                        b_cmiss[i], b_calloc[i], b_cfree[i], b_cerrs[i],
                        b_cpool[i], b_oom[i]);
            if (r != 16) begin
                $display("batches.txt parse error at batch %0d (r=%0d)", i, r);
                $finish;
            end
            for (j = 0; j < b_nfree[i]; j = j + 1) begin
                r = $fscanf(fd, "%h", w);
                b_seed[i][j] = w;
            end
        end
        $fclose(fd);
    end endtask

    // ================= MMIO =================
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

    task expect_eq(input [255:0] what, input [31:0] got, input [31:0] exp);
    begin
        checks = checks + 1;
        if (got !== exp) begin
            mismatch = mismatch + 1;
            $display("  MISMATCH %0s: got %08x expected %08x", what, got, exp);
        end
    end endtask

    // ================= one batch =================
    task run_batch(input integer b, input integer measure);
        integer i, guard;
        reg [31:0] st, v;
    begin
        if (b_reset[b]) reg_write(R_CTRL, CTRL_SRST);
        for (i = 0; i < b_nfree[b]; i = i + 1)
            reg_write(R_FREE_PUSH, b_seed[b][i]);

        reg_write(R_BT_BASE,   `BT_BASE_W * 4);
        reg_write(R_BT_STRIDE, `BT_STRIDE);
        reg_write(R_REQ_BASE,  b_reqw[b] * 4);
        reg_write(R_RES_BASE,  b_resw[b] * 4);
        reg_write(R_REQ_COUNT, b_nreq[b]);
        reg_write(R_CTRL,      CTRL_START | CTRL_IRQEN);

        guard = 0;
        st = 0;
        while ((st & ST_DONE) == 0) begin
            reg_read(R_STATUS, st);
            guard = guard + 1;
            if (guard > 500000) begin
                $display("  TIMEOUT waiting for DONE in batch %0d", b);
                mismatch = mismatch + 1;
                st = ST_DONE;
            end
        end

        // interrupt must be up while a sticky bit is set and IRQ_EN is on
        expect_eq("irq asserted", {31'b0, irq}, 32'd1);
        expect_eq("status.oom", (st & ST_OOM) ? 32'd1 : 32'd0,
                  b_oom[b] ? 32'd1 : 32'd0);
        expect_eq("status.bus", (st & ST_BUS) ? 32'd1 : 32'd0, 32'd0);

        // ---- result words in memory ----
        for (i = 0; i < b_nres[b]; i = i + 1) begin
            checks = checks + 1;
            if (mem[b_resw[b] + i] !== gres[(b_resw[b] - `RES_BASE_W) + i]) begin
                mismatch = mismatch + 1;
                if (mismatch < 25)
                    $display("  MISMATCH batch %0d result[%0d]: got %08x expected %08x",
                             b, i, mem[b_resw[b] + i],
                             gres[(b_resw[b] - `RES_BASE_W) + i]);
            end
        end

        // ---- statistics / pool / result count ----
        reg_read(R_RES_WORDS,   v); expect_eq("res_words",   v, b_nres[b]);
        reg_read(R_STAT_REQS,   v); expect_eq("stat_reqs",   v, b_creqs[b]);
        reg_read(R_STAT_XLATES, v); expect_eq("stat_xlates", v, b_cxl[b]);
        reg_read(R_STAT_HITS,   v); expect_eq("stat_hits",   v, b_chits[b]);
        reg_read(R_STAT_MISSES, v); expect_eq("stat_misses", v, b_cmiss[b]);
        reg_read(R_STAT_ALLOCS, v); expect_eq("stat_allocs", v, b_calloc[b]);
        reg_read(R_STAT_FREES,  v); expect_eq("stat_frees",  v, b_cfree[b]);
        reg_read(R_STAT_ERRS,   v); expect_eq("stat_errs",   v, b_cerrs[b]);
        reg_read(R_FREE_COUNT,  v); expect_eq("free_count",  v, b_cpool[b]);

        reg_read(R_LAST_CYC, v);
        if (measure) begin
            b_cycles[b] = v;
            pass_cycles = pass_cycles + v;
        end else begin
            bubble_cycles = bubble_cycles + v;
        end

        reg_write(R_IRQ_ACK, ST_DONE | ST_OOM | ST_BUS);
        reg_read(R_STATUS, st);
        expect_eq("sticky cleared", st & (ST_DONE | ST_OOM | ST_BUS), 32'd0);
        expect_eq("irq deasserted", {31'b0, irq}, 32'd0);
    end endtask

    integer passa_waits = 0, passb_xacts = 0;

    task run_pass(input integer wmax_i, input integer measure);
        integer b;
    begin
        wmax  = wmax_i;
        xacts = 0;
        wait_cycles = 0;
        $readmemh("mem_init.hex", mem);
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);
        for (b = 0; b < NB; b = b + 1) run_batch(b, measure);
        // ---- the whole block table must match the golden model ----
        for (b = 0; b < BTW; b = b + 1) begin
            checks = checks + 1;
            if (mem[`BT_BASE_W + b] !== gbt[b]) begin
                mismatch = mismatch + 1;
                if (mismatch < 25)
                    $display("  MISMATCH block_table[%0d]: got %08x expected %08x",
                             b, mem[`BT_BASE_W + b], gbt[b]);
            end
        end
    end endtask

    // ================= error-path directed tests =================
    task test_bus_error;
        integer guard;
        reg [31:0] st, v;
    begin
        $display("-- directed: Wishbone ERR_I on a block-table address --");
        wmax = 0;
        $readmemh("mem_init.hex", mem);
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        reg_write(R_CTRL, CTRL_SRST);
        reg_write(R_FREE_PUSH, 32'h55);
        reg_write(R_BT_BASE,   `BT_BASE_W * 4);
        reg_write(R_BT_STRIDE, `BT_STRIDE);
        reg_write(R_REQ_BASE,  b_reqw[0] * 4);
        reg_write(R_RES_BASE,  b_resw[0] * 4);
        reg_write(R_REQ_COUNT, 1);
        // block_table[seq 1][0] is the first entry the batch-0 request walks
        poison_addr = (`BT_BASE_W + 1 * `BT_STRIDE) * 4;
        reg_write(R_CTRL, CTRL_START | CTRL_IRQEN);

        guard = 0; st = 0;
        while ((st & ST_DONE) == 0 && guard < 5000) begin
            reg_read(R_STATUS, st); guard = guard + 1;
        end
        expect_eq("buserr: done", (st & ST_DONE) ? 32'd1 : 32'd0, 32'd1);
        expect_eq("buserr: sticky bus", (st & ST_BUS) ? 32'd1 : 32'd0, 32'd1);
        expect_eq("buserr: irq", {31'b0, irq}, 32'd1);
        reg_read(R_STAT_ERRS, v);
        expect_eq("buserr: errs", (v >= 1) ? 32'd1 : 32'd0, 32'd1);
        reg_write(R_IRQ_ACK, ST_DONE | ST_OOM | ST_BUS);
        reg_read(R_STATUS, st);
        expect_eq("buserr: cleared", st & (ST_DONE | ST_BUS), 32'd0);
        poison_addr = 32'hFFFF_FFFF;
    end endtask

    task test_bus_hang;
        integer guard;
        reg [31:0] st;
    begin
        $display("-- directed: unacknowledged cycle -> master watchdog --");
        reg_write(R_CTRL, CTRL_SRST);
        reg_write(R_REQ_BASE,  b_reqw[1] * 4);
        reg_write(R_RES_BASE,  b_resw[1] * 4);
        reg_write(R_REQ_COUNT, 1);
        hang = 1;
        reg_write(R_CTRL, CTRL_START | CTRL_IRQEN);
        guard = 0; st = 0;
        while ((st & ST_DONE) == 0 && guard < 5000) begin
            reg_read(R_STATUS, st); guard = guard + 1;
        end
        hang = 0;
        expect_eq("hang: done", (st & ST_DONE) ? 32'd1 : 32'd0, 32'd1);
        expect_eq("hang: sticky bus", (st & ST_BUS) ? 32'd1 : 32'd0, 32'd1);
        reg_write(R_IRQ_ACK, ST_DONE | ST_OOM | ST_BUS);
    end endtask

    // ================= main =================
    integer i;
    reg [31:0] v;
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("results/kvp.vcd");
            $dumpvars(0, kvp_tb);
        end
        $readmemh("golden_res.hex", gres);
        $readmemh("golden_bt.hex",  gbt);
        load_batches();
        for (i = 0; i < NB; i = i + 1) b_cycles[i] = 0;

        $display("=== KV-cache paging engine: differential test ===");
        $display("batches=%0d results=%0d sets=%0d ways=%0d pool=%0d",
                 NB, TOT_RES, `CFG_SETS, `CFG_WAYS, `CFG_FREE_DEPTH);

        rst_n = 0; repeat (5) @(posedge clk); rst_n = 1; @(posedge clk);
        reg_read(R_VERSION, v); expect_eq("version", v, EXP_VERSION);
        reg_read(R_STATUS,  v); expect_eq("idle status", v, 32'd0);
        reg_read(R_FREE_COUNT, v); expect_eq("pool empty at reset", v, 32'd0);

        $display("-- pass A: randomised memory wait states (0..3) --");
        run_pass(3, 0);
        passa_waits = wait_cycles;
        $display("   pass A: %0d checks, %0d mismatches, %0d cycles",
                 checks, mismatch, bubble_cycles);

        $display("-- pass B: zero-wait-state memory (full rate) --");
        run_pass(0, 1);
        passb_xacts = xacts;
        $display("   pass B: %0d checks, %0d mismatches, %0d cycles",
                 checks, mismatch, pass_cycles);

        test_bus_error();
        test_bus_hang();

        // ---- measured numbers ----
        $display("MET checks %0d", checks);
        $display("MET mismatches %0d", mismatch);
        $display("MET batches %0d", NB);
        $display("MET results %0d", TOT_RES);
        $display("MET fullrate_cycles %0d", pass_cycles);
        $display("MET bubble_cycles %0d", bubble_cycles);
        $display("MET bus_xacts %0d", passb_xacts);
        $display("MET stall_cycles %0d", passa_waits);
        $display("MET peak_batch_index %0d", PEAK_B);
        $display("MET peak_batch_cycles %0d", b_cycles[PEAK_B]);
        $display("MET peak_batch_xlates %0d", b_dxl[PEAK_B]);
        $display("MET latency_cycles %0d", b_cycles[LAT_B]);
        for (i = 0; i < NB; i = i + 1)
            $display("BATCH %0d cycles %0d xlates %0d results %0d",
                     i, b_cycles[i], b_dxl[i], b_nres[i]);

        if (mismatch == 0) $display("TEST PASSED - %0d checks, 0 mismatches", checks);
        else               $display("TEST FAILED - %0d mismatches of %0d checks",
                                    mismatch, checks);
        $finish;
    end
endmodule

`default_nettype wire
