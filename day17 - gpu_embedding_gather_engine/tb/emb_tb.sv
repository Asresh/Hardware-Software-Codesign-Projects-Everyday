// ============================================================================
// emb_tb - differential testbench for the sharded embedding gather-reduce engine.
//
// The engine is checked against the C golden model (sw/emb_model.c) word for word
// over the whole output region, and register for register against the statistics
// the same model counts.  Five runs per pass:
//
//   A  randomised AXI wait states on all five channels, ping-pong buffers
//   B  full-rate bus, ping-pong buffers          -> sustained throughput
//   C  full-rate bus, single-buffer mode         -> the double-buffering A/B
//   D  the peak descriptor alone, full rate      -> steady-state throughput
//   E  directed error / corner runs: read SLVERR, AR watchdog, zero-length ring,
//      register readback and device ID
//
// A, B and C must produce byte-identical memory images: the pooled result is a
// function of the descriptor ring, never of the bus timing or the buffering mode.
// Runs also check that the engine writes *nothing* outside the output region.
// ============================================================================
`timescale 1ns / 1ps
`include "emb_const.vh"

module emb_tb;
    localparam DIM     = `G_DIM;
    localparam LANES   = `G_LANES;
    localparam CHUNKS  = `G_CHUNKS;
    localparam DW      = LANES * 32;
    localparam MEMW    = `G_MEM_WORDS;
    localparam MEMUSED = `G_MEM_USED;
    localparam NDESC   = `G_NDESC;
    localparam OUTW    = `G_OUT_WORDS;

    // register offsets (byte address)
    localparam R_CTRL = 8'h00, R_STATUS = 8'h04, R_IRQ = 8'h08,
               R_DESCB = 8'h0C, R_DESCN = 8'h10, R_IDXB = 8'h14,
               R_TABB = 8'h18, R_OUTB = 8'h1C, R_SLO = 8'h20,
               R_SHI = 8'h24, R_ROWS = 8'h28, R_STDESC = 8'h2C,
               R_STIDX = 8'h30, R_STLOC = 8'h34, R_STREM = 8'h38,
               R_STINV = 8'h3C, R_STRB = 8'h40, R_STWB = 8'h44,
               R_STCYC = 8'h48, R_ID = 8'h4C;

    localparam C_START = 32'h1, C_SINGLE = 32'h2, C_IRQEN = 32'h4, C_CLRST = 32'h8;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    // ------------------------------------------------------------ MMIO plane
    reg         reg_sel = 1'b0, reg_we = 1'b0;
    reg  [7:0]  reg_addr = 8'h0;
    reg  [31:0] reg_wdata = 32'h0;
    wire [31:0] reg_rdata;
    wire        irq;

    // ------------------------------------------------------------- AXI4 wires
    wire            m_arvalid;
    reg             m_arready;
    wire [31:0]     m_araddr;
    wire [7:0]      m_arlen;
    wire [2:0]      m_arsize;
    wire [1:0]      m_arburst;
    reg             m_rvalid;
    wire            m_rready;
    reg  [DW-1:0]   m_rdata;
    reg  [1:0]      m_rresp;
    reg             m_rlast;

    wire            m_awvalid;
    reg             m_awready;
    wire [31:0]     m_awaddr;
    wire [7:0]      m_awlen;
    wire [2:0]      m_awsize;
    wire [1:0]      m_awburst;
    wire            m_wvalid;
    reg             m_wready;
    wire [DW-1:0]   m_wdata;
    wire [DW/8-1:0] m_wstrb;
    wire            m_wlast;
    reg             m_bvalid;
    wire            m_bready;
    reg  [1:0]      m_bresp;

    emb_top #(.DIM(DIM), .LANES(LANES), .MAX_BAG(`G_MAX_BAG)) dut (
        .clk(clk), .rst(rst),
        .reg_sel(reg_sel), .reg_we(reg_we), .reg_addr(reg_addr),
        .reg_wdata(reg_wdata), .reg_rdata(reg_rdata), .irq(irq),
        .m_arvalid(m_arvalid), .m_arready(m_arready), .m_araddr(m_araddr),
        .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
        .m_rvalid(m_rvalid), .m_rready(m_rready), .m_rdata(m_rdata),
        .m_rresp(m_rresp), .m_rlast(m_rlast),
        .m_awvalid(m_awvalid), .m_awready(m_awready), .m_awaddr(m_awaddr),
        .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst),
        .m_wvalid(m_wvalid), .m_wready(m_wready), .m_wdata(m_wdata),
        .m_wstrb(m_wstrb), .m_wlast(m_wlast),
        .m_bvalid(m_bvalid), .m_bready(m_bready), .m_bresp(m_bresp)
    );

    // ============================================================ memory model
    reg [31:0] mem  [0:MEMW-1];
    reg [31:0] ref_mem [0:MEMW-1];
    reg [31:0] gold [0:OUTW-1];

    // knobs the test sequence drives
    reg wait_states = 1'b0;
    reg stall_ar    = 1'b0;
    reg inject_rerr = 1'b0;

    // deterministic testbench PRNG (bus gap generation must be reproducible)
    reg [31:0] tbrng = 32'h9E3779B9;
    function [31:0] nxt;
        begin
            tbrng = tbrng ^ (tbrng << 13);
            tbrng = tbrng ^ (tbrng >> 17);
            tbrng = tbrng ^ (tbrng << 5);
            nxt = tbrng;
        end
    endfunction
    function [2:0] gap;   // 0..3 idle cycles before the next beat
        begin
            gap = wait_states ? (nxt() & 3) : 3'd0;
        end
    endfunction

    // ---------------------------------------------------------- read channel
    localparam RS_IDLE = 1'b0, RS_BEAT = 1'b1;
    reg        rs;
    integer    rbase, rlen, rbeat;
    reg [2:0]  rgap;
    integer    axi_rbeats, axi_wbeats;

    task load_rbeat;
        integer k;
        begin
            for (k = 0; k < LANES; k = k + 1)
                m_rdata[32*k +: 32] <= mem[rbase + rbeat*LANES + k];
            m_rlast <= (rbeat == rlen);
            m_rresp <= inject_rerr ? 2'b10 : 2'b00;
            m_rvalid <= 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            m_arready <= 1'b0;
            m_rvalid  <= 1'b0;
            m_rlast   <= 1'b0;
            m_rresp   <= 2'b00;
            rs        <= RS_IDLE;
            rbase = 0; rlen = 0; rbeat = 0; rgap = 0;
        end else begin
            case (rs)
            RS_IDLE: begin
                m_rvalid <= 1'b0;
                if (m_arvalid && m_arready) begin
                    rbase = m_araddr >> 2;
                    rlen  = m_arlen;
                    rbeat = 0;
                    rgap  = gap();
                    m_arready <= 1'b0;
                    rs        <= RS_BEAT;
                    if (rgap == 0) load_rbeat();
                end else begin
                    m_arready <= !stall_ar;
                end
            end

            RS_BEAT: begin
                m_arready <= 1'b0;
                if (m_rvalid && m_rready) begin
                    axi_rbeats = axi_rbeats + 1;
                    if (rbeat == rlen) begin
                        m_rvalid  <= 1'b0;
                        rs        <= RS_IDLE;
                        m_arready <= !stall_ar;
                    end else begin
                        rbeat = rbeat + 1;
                        rgap  = gap();
                        if (rgap == 0) load_rbeat();
                        else           m_rvalid <= 1'b0;
                    end
                end else if (!m_rvalid) begin
                    if (rgap == 0) load_rbeat();
                    else rgap = rgap - 1;
                end
            end
            endcase
        end
    end

    // --------------------------------------------------------- write channel
    localparam WS_IDLE = 2'd0, WS_DATA = 2'd1, WS_RESP = 2'd2;
    reg [1:0] ws;
    integer   wbase, wlen, wbeat;

    integer wk;
    always @(posedge clk) begin
        if (rst) begin
            m_awready <= 1'b0;
            m_wready  <= 1'b0;
            m_bvalid  <= 1'b0;
            m_bresp   <= 2'b00;
            ws        <= WS_IDLE;
            wbase = 0; wlen = 0; wbeat = 0;
        end else begin
            case (ws)
            WS_IDLE: begin
                m_bvalid <= 1'b0;
                m_wready <= 1'b0;
                if (m_awvalid && m_awready) begin
                    wbase = m_awaddr >> 2;
                    wlen  = m_awlen;
                    wbeat = 0;
                    m_awready <= 1'b0;
                    m_wready  <= !wait_states || ((nxt() & 3) != 0);
                    ws        <= WS_DATA;
                end else begin
                    m_awready <= 1'b1;
                end
            end

            WS_DATA: begin
                m_awready <= 1'b0;
                if (m_wvalid && m_wready) begin
                    for (wk = 0; wk < LANES; wk = wk + 1)
                        mem[wbase + wbeat*LANES + wk] = m_wdata[32*wk +: 32];
                    axi_wbeats = axi_wbeats + 1;
                    if (m_wlast) begin
                        m_wready <= 1'b0;
                        m_bvalid <= 1'b1;
                        m_bresp  <= 2'b00;
                        ws       <= WS_RESP;
                    end else begin
                        wbeat = wbeat + 1;
                        m_wready <= !wait_states || ((nxt() & 3) != 0);
                    end
                end else begin
                    m_wready <= !wait_states || ((nxt() & 3) != 0);
                end
            end

            WS_RESP: begin
                if (m_bready) begin
                    m_bvalid  <= 1'b0;
                    ws        <= WS_IDLE;
                    m_awready <= 1'b1;
                end
            end

            default: ws <= WS_IDLE;
            endcase
        end
    end

    // ============================================================== bookkeeping
    integer checks = 0;
    integer errors = 0;
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    task chk32(input [255:0] what, input [31:0] got, input [31:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("  MISMATCH %0s: got %08x expected %08x", what, got, exp);
            end
        end
    endtask

    // -------------------------------------------------------------- CSR access
    task csr_wr(input [7:0] a, input [31:0] d);
        begin
            @(negedge clk);
            reg_sel = 1'b1; reg_we = 1'b1; reg_addr = a; reg_wdata = d;
            @(negedge clk);
            reg_sel = 1'b0; reg_we = 1'b0;
        end
    endtask

    task csr_rd(input [7:0] a, output [31:0] d);
        begin
            @(negedge clk);
            reg_sel = 1'b1; reg_we = 1'b0; reg_addr = a;
            @(negedge clk);
            reg_sel = 1'b0;
            d = reg_rdata;
        end
    endtask

    // ------------------------------------------------------------- run control
    integer w, d, base, timeout;
    reg [31:0] rv, st_desc, st_idx, st_loc, st_rem, st_inv, st_rb, st_wb, st_cyc;
    integer cyc_wait, cyc_full, cyc_single, cyc_peak;
    integer rb_full, wb_full;

    task poison_out;
        integer i;
        begin
            for (i = 0; i < OUTW; i = i + 1) mem[`G_OUT_BASE + i] = `G_POISON;
        end
    endtask

    task program_cfg;
        begin
            csr_wr(R_IDXB, `G_IDX_BASE);
            csr_wr(R_TABB, `G_TAB_BASE);
            csr_wr(R_OUTB, `G_OUT_BASE);
            csr_wr(R_SLO,  `G_SHARD_LO);
            csr_wr(R_SHI,  `G_SHARD_HI);
            csr_wr(R_ROWS, `G_TABLE_ROWS);
        end
    endtask

    // launch a run and wait for STATUS.DONE
    task run(input [31:0] dbase, input [31:0] dcount, input single);
        reg [31:0] ctrl;
        begin
            axi_rbeats = 0;
            axi_wbeats = 0;
            ctrl = C_IRQEN | (single ? C_SINGLE : 32'h0);
            csr_wr(R_DESCB, dbase);
            csr_wr(R_DESCN, dcount);
            program_cfg();
            csr_wr(R_IRQ, 32'h3);              // clear stale flags
            csr_wr(R_CTRL, ctrl | C_CLRST);
            csr_wr(R_CTRL, ctrl | C_START);
            timeout = 0;
            rv = 0;
            while (!(rv & 32'h2) && timeout < 4000000) begin
                csr_rd(R_STATUS, rv);
                timeout = timeout + 1;
            end
            if (!(rv & 32'h2)) begin
                $display("  FATAL: run did not complete (timeout)");
                errors = errors + 1;
            end
        end
    endtask

    task read_stats;
        begin
            csr_rd(R_STDESC, st_desc);
            csr_rd(R_STIDX,  st_idx);
            csr_rd(R_STLOC,  st_loc);
            csr_rd(R_STREM,  st_rem);
            csr_rd(R_STINV,  st_inv);
            csr_rd(R_STRB,   st_rb);
            csr_rd(R_STWB,   st_wb);
            csr_rd(R_STCYC,  st_cyc);
        end
    endtask

    // compare the whole output region against the golden image
    task check_outputs(input [255:0] tag);
        integer i, bad0;
        begin
            bad0 = errors;
            for (i = 0; i < OUTW; i = i + 1) begin
                checks = checks + 1;
                if (mem[`G_OUT_BASE + i] !== gold[i]) begin
                    errors = errors + 1;
                    if (errors - bad0 <= 10)
                        $display("  MISMATCH %0s out[%0d] (desc %0d elem %0d): got %08x expected %08x",
                                 tag, i, i / DIM, i % DIM,
                                 mem[`G_OUT_BASE + i], gold[i]);
                end
            end
        end
    endtask

    // the engine must not write a single word outside the output region
    task check_untouched;
        integer i, bad0;
        begin
            bad0 = errors;
            for (i = 0; i < `G_OUT_BASE; i = i + 1) begin
                checks = checks + 1;
                if (mem[i] !== ref_mem[i]) begin
                    errors = errors + 1;
                    if (errors - bad0 <= 5)
                        $display("  MISMATCH engine wrote outside the output region at word %0d: %08x (was %08x)",
                                 i, mem[i], ref_mem[i]);
                end
            end
        end
    endtask

    task check_stats;
        begin
            read_stats();
            chk32("stat desc",    st_desc, `G_ST_DESC);
            chk32("stat idx",     st_idx,  `G_ST_IDX);
            chk32("stat local",   st_loc,  `G_ST_LOCAL);
            chk32("stat remote",  st_rem,  `G_ST_REMOTE);
            chk32("stat invalid", st_inv,  `G_ST_INVALID);
            chk32("stat rbeats",  st_rb,   `G_ST_RBEATS);
            chk32("stat wbeats",  st_wb,   `G_ST_WBEATS);
            // the register counters must agree with what actually moved on AXI
            chk32("axi rbeats",   axi_rbeats, `G_ST_RBEATS);
            chk32("axi wbeats",   axi_wbeats, `G_ST_WBEATS);
        end
    endtask

    // ================================================================== main
    initial begin
        $display("=====================================================================");
        $display(" Day 17 - sharded embedding gather-reduce engine");
        $display("   DIM=%0d LANES=%0d CHUNKS=%0d MAX_BAG=%0d  shard=[%0d,%0d) of %0d rows",
                 DIM, LANES, CHUNKS, `G_MAX_BAG, `G_SHARD_LO, `G_SHARD_HI, `G_TABLE_ROWS);
        $display("   %0d descriptors (%0d directed + %0d randomised), %0d output words",
                 NDESC, `G_NDIRECTED, NDESC - `G_NDIRECTED, OUTW);
        $display("=====================================================================");

        for (w = 0; w < MEMW; w = w + 1) mem[w] = 32'h0;
        $readmemh("mem_init.hex", mem);
        $readmemh("mem_init.hex", ref_mem);
        $readmemh("golden_out.hex", gold);

        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ------------------------------------------------------ device ID / CSR
        csr_rd(R_ID, rv);
        chk32("device id", rv, 32'hE9B00000 | (CHUNKS << 8) | LANES);

        program_cfg();
        csr_rd(R_IDXB, rv); chk32("csr idx_base",  rv, `G_IDX_BASE);
        csr_rd(R_TABB, rv); chk32("csr tab_base",  rv, `G_TAB_BASE);
        csr_rd(R_OUTB, rv); chk32("csr out_base",  rv, `G_OUT_BASE);
        csr_rd(R_SLO,  rv); chk32("csr shard_lo",  rv, `G_SHARD_LO);
        csr_rd(R_SHI,  rv); chk32("csr shard_hi",  rv, `G_SHARD_HI);
        csr_rd(R_ROWS, rv); chk32("csr tab_rows",  rv, `G_TABLE_ROWS);

        // ================================================== A: randomised waits
        $display("\n[A] full ring, randomised AXI wait states, ping-pong buffers");
        poison_out();
        wait_states = 1'b1;
        run(`G_DESC_BASE, NDESC, 1'b0);
        cyc_wait = st_cyc;
        check_outputs("A");
        check_untouched();
        check_stats();
        cyc_wait = st_cyc;
        csr_rd(R_STATUS, rv);
        chk32("A status err_baglen", (rv >> 2) & 1, (`G_ST_BAGLEN > 0) ? 1 : 0);
        chk32("A status err_index",  (rv >> 3) & 1, (`G_ST_INVALID > 0) ? 1 : 0);
        chk32("A status err_bus",    (rv >> 4) & 1, 0);
        csr_rd(R_IRQ, rv);
        chk32("A irq done",  rv & 1,        1);
        chk32("A irq error", (rv >> 1) & 1, 1);
        checks = checks + 1;
        if (irq !== 1'b1) begin
            errors = errors + 1;
            $display("  MISMATCH irq line not asserted after run A");
        end
        $display("    %0d cycles, %0d read beats, %0d write beats, %0d errors so far",
                 cyc_wait, axi_rbeats, axi_wbeats, errors);

        // interrupt acknowledge must drop the line
        csr_wr(R_IRQ, 32'h3);
        @(posedge clk);
        checks = checks + 1;
        if (irq !== 1'b0) begin
            errors = errors + 1;
            $display("  MISMATCH irq line still asserted after W1C acknowledge");
        end

        // ======================================================== B: full rate
        $display("\n[B] full ring, full-rate bus, ping-pong buffers");
        poison_out();
        wait_states = 1'b0;
        run(`G_DESC_BASE, NDESC, 1'b0);
        check_outputs("B");
        check_untouched();
        check_stats();
        cyc_full = st_cyc;
        rb_full  = axi_rbeats;
        wb_full  = axi_wbeats;
        $display("    %0d cycles, %0d read beats, %0d write beats",
                 cyc_full, rb_full, wb_full);

        // ================================================= C: single-buffer A/B
        $display("\n[C] full ring, full-rate bus, single-buffer mode (overlap off)");
        poison_out();
        wait_states = 1'b0;
        run(`G_DESC_BASE, NDESC, 1'b1);
        check_outputs("C");
        check_untouched();
        check_stats();
        cyc_single = st_cyc;
        $display("    %0d cycles (results identical to [B], only slower)", cyc_single);

        // ============================================== D: peak descriptor alone
        $display("\n[D] peak descriptor %0d alone, full-rate bus", `G_PEAK_DESC);
        poison_out();
        wait_states = 1'b0;
        run(`G_DESC_BASE + `G_PEAK_DESC * `G_DESC_WORDS, 1, 1'b0);
        read_stats();
        cyc_peak = st_cyc;
        chk32("peak local rows", st_loc, `G_PEAK_LOCAL);
        chk32("peak read beats", st_rb,  `G_PEAK_RBEATS);
        chk32("peak write beats", st_wb, `G_PEAK_WBEATS);
        base = `G_PEAK_DESC * DIM;
        for (w = 0; w < DIM; w = w + 1) begin
            checks = checks + 1;
            if (mem[`G_OUT_BASE + base + w] !== gold[base + w]) begin
                errors = errors + 1;
                if (errors < 20)
                    $display("  MISMATCH D out[%0d]: got %08x expected %08x",
                             w, mem[`G_OUT_BASE + base + w], gold[base + w]);
            end
        end
        $display("    %0d cycles for %0d rows x %0d beats", cyc_peak,
                 `G_PEAK_LOCAL, CHUNKS);

        // ============================================ E: directed error / corner
        $display("\n[E] directed error and corner runs");

        // E1 zero-length ring: completes immediately, moves no data
        poison_out();
        run(`G_DESC_BASE, 0, 1'b0);
        read_stats();
        chk32("E1 zero-ring desc",   st_desc, 0);
        chk32("E1 zero-ring rbeats", st_rb,   0);
        chk32("E1 zero-ring wbeats", st_wb,   0);
        csr_rd(R_STATUS, rv);
        chk32("E1 zero-ring done",   (rv >> 1) & 1, 1);
        chk32("E1 zero-ring errors", (rv >> 2) & 7, 0);
        $display("    E1 zero-length ring: done with no bus traffic");

        // E2 read SLVERR: sticky bus error, error IRQ, engine returns to idle
        poison_out();
        inject_rerr = 1'b1;
        run(`G_DESC_BASE, 4, 1'b0);
        inject_rerr = 1'b0;
        csr_rd(R_STATUS, rv);
        chk32("E2 err_bus set", (rv >> 4) & 1, 1);
        chk32("E2 not busy",    rv & 1,        0);
        csr_rd(R_IRQ, rv);
        chk32("E2 irq error",   (rv >> 1) & 1, 1);
        $display("    E2 read SLVERR: bus error latched, walk aborted, not hung");

        // E3 AR watchdog: a slave that never accepts an address must not hang us
        poison_out();
        stall_ar = 1'b1;
        run(`G_DESC_BASE, 4, 1'b0);
        stall_ar = 1'b0;
        csr_rd(R_STATUS, rv);
        chk32("E3 watchdog err_bus", (rv >> 4) & 1, 1);
        chk32("E3 watchdog idle",    rv & 1,        0);
        $display("    E3 AR watchdog: wedged slave detected, walk aborted");

        // E4 recover: after the two fault runs a clean full-rate run must be
        //    bit-exact again, proving the faults left no residue
        $display("\n[F] recovery run after the injected faults");
        poison_out();
        wait_states = 1'b0;
        run(`G_DESC_BASE, NDESC, 1'b0);
        check_outputs("F");
        check_untouched();
        check_stats();
        csr_rd(R_STATUS, rv);
        chk32("F err_bus cleared", (rv >> 4) & 1, 0);
        $display("    %0d cycles, bit-exact after fault recovery", st_cyc);

        // ==================================================== metrics + verdict
        $display("\n---------------------------------------------------------------------");
        $display("METRIC descriptors %0d",      NDESC);
        $display("METRIC directed %0d",         `G_NDIRECTED);
        $display("METRIC random %0d",           NDESC - `G_NDIRECTED);
        $display("METRIC indices %0d",          `G_ST_IDX);
        $display("METRIC local_rows %0d",       `G_ST_LOCAL);
        $display("METRIC remote_indices %0d",   `G_ST_REMOTE);
        $display("METRIC invalid_indices %0d",  `G_ST_INVALID);
        $display("METRIC baglen_rejects %0d",   `G_ST_BAGLEN);
        $display("METRIC read_beats %0d",       `G_ST_RBEATS);
        $display("METRIC write_beats %0d",      `G_ST_WBEATS);
        $display("METRIC output_words %0d",     OUTW);
        $display("METRIC cycles_wait %0d",      cyc_wait);
        $display("METRIC cycles_full %0d",      cyc_full);
        $display("METRIC cycles_single %0d",    cyc_single);
        $display("METRIC cycles_peak %0d",      cyc_peak);
        $display("METRIC peak_local_rows %0d",  `G_PEAK_LOCAL);
        $display("METRIC peak_read_beats %0d",  `G_PEAK_RBEATS);
        $display("METRIC peak_write_beats %0d", `G_PEAK_WBEATS);
        $display("METRIC baseline_cycles %0d",  `G_BASE_CYC);
        $display("METRIC peak_baseline_cycles %0d", `G_PEAK_BASE_CYC);
        $display("METRIC dim %0d",              DIM);
        $display("METRIC lanes %0d",            LANES);
        $display("METRIC chunks %0d",           CHUNKS);
        $display("METRIC max_bag %0d",          `G_MAX_BAG);
        $display("METRIC checks %0d",           checks);
        $display("METRIC mismatches %0d",       errors);
        $display("---------------------------------------------------------------------");

        if (errors == 0) $display("TEST PASSED  (%0d checks, 0 mismatches)", checks);
        else             $display("TEST FAILED  (%0d checks, %0d mismatches)", checks, errors);
        $finish;
    end

    // global safety net so a hang shows up as a failure, not a stuck simulation
    initial begin
        #400000000;
        $display("TEST FAILED  (global simulation timeout)");
        $finish;
    end
endmodule
