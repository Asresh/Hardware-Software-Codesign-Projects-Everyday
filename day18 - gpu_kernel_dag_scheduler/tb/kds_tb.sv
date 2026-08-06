// ============================================================================
// kds_tb.sv - differential testbench for the kernel-DAG scheduler.
//
// The host program (sw/kds_host.c) writes the whole experiment out: an initial
// memory image containing every graph, the memory image as it must look when
// the last graph retires, and a line per launch holding every value the CSRs
// have to report. This testbench replays that and compares.
//
//   pass 0  randomised wait states on all five AXI4-Lite memory channels
//   pass 1  full rate, zero wait states
//
// Both passes must produce identical results - byte for byte in memory and
// value for value in the CSRs - which is the point: the schedule is a function
// of the graph, never of bus timing. After each pass the *entire* memory is
// compared against the golden image, so a stray write anywhere outside a
// result region is a failure.
//
// On top of the per-graph comparison the testbench checks the two structural
// identities the design guarantees:
//     makespan      == dispatched + stall + depwait
//     sum(dev_busy) == serial_ticks
// and finishes with directed tests for read and write bus errors, interrupt
// masking, W1C behaviour, unknown-register reads and the CAPS register.
// ============================================================================
`timescale 1ns/1ps
`include "kds_defs.vh"
`include "kds_const.vh"

module kds_tb;

    localparam MAX_NODES  = `KDS_TB_MAX_NODES;
    localparam DEVICES    = `KDS_TB_DEVICES;
    localparam NODE_WORDS = `KDS_TB_NODE_WORDS;
    localparam NG         = `KDS_TB_NGRAPHS;
    localparam MEMW       = `KDS_TB_MEMW;
    localparam PEAK_IDX   = `KDS_TB_PEAK_IDX;

    // ------------------------------------------------------------------ clock
    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    reg [63:0] cycles = 64'd0;
    always @(posedge clk) cycles <= cycles + 64'd1;

    // ------------------------------------------------------- control (master)
    reg  [11:0] cs_awaddr;  reg cs_awvalid;  wire cs_awready;
    reg  [31:0] cs_wdata;   reg [3:0] cs_wstrb; reg cs_wvalid; wire cs_wready;
    wire [1:0]  cs_bresp;   wire cs_bvalid;  reg cs_bready;
    reg  [11:0] cs_araddr;  reg cs_arvalid;  wire cs_arready;
    wire [31:0] cs_rdata;   wire [1:0] cs_rresp; wire cs_rvalid; reg cs_rready;

    // --------------------------------------------------- memory port (slave)
    wire [31:0] m_awaddr, m_wdata, m_araddr;
    wire [3:0]  m_wstrb;
    wire        m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;
    wire        m_awready, m_wready, m_arready;
    reg         m_bvalid, m_rvalid;
    reg  [1:0]  m_bresp, m_rresp;
    reg  [31:0] m_rdata;
    wire        irq;

    kds_top #(.MAX_NODES(MAX_NODES), .DEVICES(DEVICES)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(cs_awaddr), .s_awvalid(cs_awvalid), .s_awready(cs_awready),
        .s_wdata(cs_wdata), .s_wstrb(cs_wstrb), .s_wvalid(cs_wvalid),
        .s_wready(cs_wready), .s_bresp(cs_bresp), .s_bvalid(cs_bvalid),
        .s_bready(cs_bready),
        .s_araddr(cs_araddr), .s_arvalid(cs_arvalid), .s_arready(cs_arready),
        .s_rdata(cs_rdata), .s_rresp(cs_rresp), .s_rvalid(cs_rvalid),
        .s_rready(cs_rready),
        .m_awaddr(m_awaddr), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wvalid(m_wvalid),
        .m_wready(m_wready), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
        .m_bready(m_bready),
        .m_araddr(m_araddr), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rvalid(m_rvalid),
        .m_rready(m_rready),
        .irq(irq)
    );

    // ==================================================== memory slave model
    //
    // A queued AXI4-Lite memory: it accepts up to SQ_MAX addresses ahead of the
    // data it returns (which is what lets the engine's pipelined master run at
    // one word per clock), returns reads strictly in order, pairs AW with W in
    // order, and inserts an independent randomised gap on each of the five
    // channels when ws_en is set.
    localparam SQ     = 8;
    localparam SQ_MAX = 4;

    reg [31:0] mem  [0:MEMW-1];
    reg [31:0] gold [0:MEMW-1];
    reg [31:0] init [0:MEMW-1];

    reg        ws_en    = 1'b1;      // randomised wait states
    reg        err_en   = 1'b0;      // SLVERR injection window
    reg [31:0] err_lo   = 32'hFFFF_FFFF, err_hi = 32'h0;
    integer    oob_hits = 0;
    integer    rd_beats = 0, wr_beats = 0, stall_cycles = 0;

    function [3:0] wsr;
        input integer chan;
        begin
            wsr = ws_en ? ($random & 4'h7) : 4'h0;
        end
    endfunction

    function slverr_hit;
        input [31:0] a;
        begin
            slverr_hit = err_en && (a >= err_lo) && (a <= err_hi);
        end
    endfunction

    reg [31:0] rq_addr  [0:SQ-1];
    reg [31:0] awq_addr [0:SQ-1];
    reg [31:0] wq_data  [0:SQ-1];
    reg [2:0]  rq_wr, rq_rd, awq_wr, awq_rd, wq_wr, wq_rd;
    reg [3:0]  rq_cnt, awq_cnt, wq_cnt;
    reg [3:0]  arc, rc, awc, wc, bc;

    assign m_arready = (rq_cnt  < SQ_MAX) && (arc == 4'd0);
    assign m_awready = (awq_cnt < SQ_MAX) && (awc == 4'd0);
    assign m_wready  = (wq_cnt  < SQ_MAX) && (wc  == 4'd0);

    wire push_r  = m_arvalid && m_arready;
    wire pop_r   = (rq_cnt != 4'd0) && (!m_rvalid || m_rready) && (rc == 4'd0);
    wire push_aw = m_awvalid && m_awready;
    wire push_w  = m_wvalid  && m_wready;
    wire do_wr   = (awq_cnt != 4'd0) && (wq_cnt != 4'd0) &&
                   (!m_bvalid || m_bready) && (bc == 4'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_rvalid <= 1'b0; m_bvalid <= 1'b0;
            m_rresp  <= 2'b00; m_bresp <= 2'b00; m_rdata <= 32'd0;
            rq_wr <= 0; rq_rd <= 0; rq_cnt <= 0;
            awq_wr <= 0; awq_rd <= 0; awq_cnt <= 0;
            wq_wr <= 0; wq_rd <= 0; wq_cnt <= 0;
            arc <= 0; rc <= 0; awc <= 0; wc <= 0; bc <= 0;
        end else begin
            // ------------------------------------------------------ read side
            if (push_r) begin
                rq_addr[rq_wr] <= m_araddr;
                rq_wr          <= rq_wr + 3'd1;
                if (m_araddr[31:2] >= MEMW) oob_hits = oob_hits + 1;
                arc <= wsr(0);
            end else if (m_arvalid && arc != 4'd0) begin
                arc          <= arc - 4'd1;
                stall_cycles  = stall_cycles + 1;
            end

            if (pop_r) begin
                m_rvalid <= 1'b1;
                m_rdata  <= mem[rq_addr[rq_rd][31:2]];
                m_rresp  <= slverr_hit(rq_addr[rq_rd]) ? 2'b10 : 2'b00;
                rq_rd    <= rq_rd + 3'd1;
                rc       <= wsr(1);
                rd_beats  = rd_beats + 1;
            end else begin
                if (m_rvalid && m_rready) m_rvalid <= 1'b0;
                if (rq_cnt != 4'd0 && rc != 4'd0) begin
                    rc           <= rc - 4'd1;
                    stall_cycles  = stall_cycles + 1;
                end
            end
            rq_cnt <= rq_cnt + {3'd0, push_r} - {3'd0, pop_r};

            // ----------------------------------------------------- write side
            if (push_aw) begin
                awq_addr[awq_wr] <= m_awaddr;
                awq_wr           <= awq_wr + 3'd1;
                if (m_awaddr[31:2] >= MEMW) oob_hits = oob_hits + 1;
                awc <= wsr(2);
            end else if (m_awvalid && awc != 4'd0) begin
                awc          <= awc - 4'd1;
                stall_cycles  = stall_cycles + 1;
            end

            if (push_w) begin
                wq_data[wq_wr] <= m_wdata;
                wq_wr          <= wq_wr + 3'd1;
                wc <= wsr(3);
            end else if (m_wvalid && wc != 4'd0) begin
                wc           <= wc - 4'd1;
                stall_cycles  = stall_cycles + 1;
            end

            if (do_wr) begin
                if (!slverr_hit(awq_addr[awq_rd]) &&
                    (awq_addr[awq_rd][31:2] < MEMW))
                    mem[awq_addr[awq_rd][31:2]] <= wq_data[wq_rd];
                m_bresp  <= slverr_hit(awq_addr[awq_rd]) ? 2'b10 : 2'b00;
                m_bvalid <= 1'b1;
                awq_rd   <= awq_rd + 3'd1;
                wq_rd    <= wq_rd  + 3'd1;
                bc       <= wsr(4);
                wr_beats  = wr_beats + 1;
            end else begin
                if (m_bvalid && m_bready) m_bvalid <= 1'b0;
                if (awq_cnt != 4'd0 && wq_cnt != 4'd0 && bc != 4'd0) begin
                    bc           <= bc - 4'd1;
                    stall_cycles  = stall_cycles + 1;
                end
            end
            awq_cnt <= awq_cnt + {3'd0, push_aw} - {3'd0, do_wr};
            wq_cnt  <= wq_cnt  + {3'd0, push_w}  - {3'd0, do_wr};
        end
    end

    // ======================================================= control-plane BFM
    // signals are driven just after a rising edge and the handshake is sampled
    // at the following falling edge, so combinational *ready is seen in the
    // cycle it is actually asserted
    task csr_write(input [11:0] a, input [31:0] d);
        begin
            @(posedge clk);
            cs_awaddr  <= a; cs_wdata <= d; cs_wstrb <= 4'hF;
            cs_awvalid <= 1'b1; cs_wvalid <= 1'b1; cs_bready <= 1'b1;
            do @(negedge clk); while (!(cs_awready && cs_wready));
            @(posedge clk);
            cs_awvalid <= 1'b0; cs_wvalid <= 1'b0;
            do @(negedge clk); while (!cs_bvalid);
            @(posedge clk);
            cs_bready <= 1'b0;
        end
    endtask

    task csr_read(input [11:0] a, output [31:0] d);
        begin
            @(posedge clk);
            cs_araddr  <= a; cs_arvalid <= 1'b1; cs_rready <= 1'b1;
            do @(negedge clk); while (!cs_arready);
            @(posedge clk);
            cs_arvalid <= 1'b0;
            do @(negedge clk); while (!cs_rvalid);
            d = cs_rdata;
            @(posedge clk);
            cs_rready <= 1'b0;
        end
    endtask

    // ============================================================ golden data
    reg [8*24-1:0] gname  [0:NG-1];
    reg [31:0] gn_cfg [0:NG-1];
    reg [31:0] gn     [0:NG-1];
    reg [31:0] gnb    [0:NG-1];
    reg [31:0] grb    [0:NG-1];
    reg [31:0] gerr   [0:NG-1];
    reg [31:0] gmk    [0:NG-1];
    reg [31:0] gdisp  [0:NG-1];
    reg [31:0] gstall [0:NG-1];
    reg [31:0] gdw    [0:NG-1];
    reg [31:0] gmc    [0:NG-1];
    reg [31:0] gser   [0:NG-1];
    reg [31:0] gdb    [0:NG-1][0:DEVICES-1];

    integer checks = 0, mismatches = 0, shown = 0;
    integer gi_cur = 0;

    task chk(input [8*24-1:0] lbl, input [31:0] got, input [31:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                mismatches = mismatches + 1;
                if (shown < 40) begin
                    shown = shown + 1;
                    $display("MISMATCH %0s graph %0d (%0s): got %08x exp %08x",
                             lbl, gi_cur, gname[gi_cur], got, exp);
                end
            end
        end
    endtask

    // ----------------------------------------------------------------- helpers
    task wait_irq(input integer limit);
        integer n;
        begin
            n = 0;
            while (!irq && n < limit) begin @(posedge clk); n = n + 1; end
            if (!irq) begin
                $display("TIMEOUT waiting for irq on graph %0d (%0s)",
                         gi_cur, gname[gi_cur]);
                $display("TEST FAILED");
                $finish;
            end
        end
    endtask

    reg [31:0] rv, st, ir;
    reg [63:0] c0, c1;
    reg [63:0] hw_cycles_total, hw_ticks_total, hw_nodes_total;
    reg [63:0] hw_serial_total, hw_peak_cycles, hw_peak_ticks;
    reg [63:0] hw_bus_cycles, hw_single_cycles, hw_peak_disp, hw_fetchw, hw_wbw;
    reg [63:0] pass_cycles [0:1];
    reg [63:0] pass_stalls [0:1];
    reg [63:0] pass_begin  [0:1];

    task run_graph(input integer gi, input integer pass);
        integer i, w, d;
        reg [31:0] sumdb;
        reg [31:0] mk, dp, sl, dw, mc, sr, fw, ww, bc_r;
        begin
            gi_cur = gi;
            csr_write(`KDS_A_IRQ_ENABLE, 32'h3);
            csr_write(`KDS_A_NUM_NODES,  gn_cfg[gi]);
            csr_write(`KDS_A_NODE_BASE,  gnb[gi]);
            csr_write(`KDS_A_RSLT_BASE,  grb[gi]);
            c0 = cycles;
            csr_write(`KDS_A_CTRL, 32'h1);
            wait_irq(2000000);
            c1 = cycles;

            csr_read(`KDS_A_STATUS, st);
            chk("errcode", (st >> 8) & 32'hF, gerr[gi]);
            chk("busy_low", st & 32'h1, 32'h0);
            chk("done_bit", (st >> 1) & 32'h1, (gerr[gi] == 0) ? 32'h1 : 32'h0);
            chk("err_bit",  (st >> 2) & 32'h1, (gerr[gi] == 0) ? 32'h0 : 32'h1);

            csr_read(`KDS_A_IRQ_STATUS, ir);
            chk("irqstat", ir, (gerr[gi] == 0) ? 32'h1 : 32'h2);
            csr_write(`KDS_A_IRQ_STATUS, ir);
            csr_read(`KDS_A_IRQ_STATUS, ir);
            chk("irq_w1c", ir, 32'h0);

            csr_read(`KDS_A_MAKESPAN,   mk);  chk("makespan",   mk, gmk[gi]);
            csr_read(`KDS_A_DISPATCHED, dp);  chk("dispatched", dp, gdisp[gi]);
            csr_read(`KDS_A_STALL,      sl);  chk("stall",      sl, gstall[gi]);
            csr_read(`KDS_A_DEPWAIT,    dw);  chk("depwait",    dw, gdw[gi]);
            csr_read(`KDS_A_MAXCONC,    mc);  chk("maxconc",    mc, gmc[gi]);
            csr_read(`KDS_A_SERIAL,     sr);  chk("serial",     sr, gser[gi]);
            csr_read(`KDS_A_FETCHW,     fw);
            chk("fetchw", fw, (gerr[gi] == `KDS_E_LEN) ? 32'h0
                                                      : gn[gi] * NODE_WORDS);
            csr_read(`KDS_A_WBW, ww);
            chk("wbw", ww, (gerr[gi] == 0) ? gn[gi] * 4 : 32'h0);
            csr_read(`KDS_A_BUSCYC, bc_r);

            sumdb = 32'd0;
            for (d = 0; d < DEVICES; d = d + 1) begin
                csr_read(`KDS_A_DEVBUSY0 + d*4, rv);
                chk("devbusy", rv, gdb[gi][d]);
                sumdb = sumdb + rv;
            end

            if (gerr[gi] == 0) begin
                // ---- the two structural identities ------------------------
                chk("ident_makespan", mk, dp + sl + dw);
                chk("ident_occupancy", sumdb, sr);
                chk("all_dispatched", dp, gn[gi]);
                // ---- the per-node schedule in memory ----------------------
                for (i = 0; i < gn[gi]; i = i + 1)
                    for (w = 0; w < 4; w = w + 1)
                        chk("result", mem[(grb[gi] >> 2) + i*4 + w],
                                      gold[(grb[gi] >> 2) + i*4 + w]);
                if (pass == 1) begin
                    hw_ticks_total  = hw_ticks_total  + mk;
                    hw_nodes_total  = hw_nodes_total  + gn[gi];
                    hw_serial_total = hw_serial_total + sr;
                end
            end else begin
                // an aborted graph must leave its result region untouched
                for (i = 0; i < 4; i = i + 1)
                    chk("poison", mem[(grb[gi] >> 2) + i],
                                  init[(grb[gi] >> 2) + i]);
            end

            if (pass == 1) begin
                hw_cycles_total = hw_cycles_total + (c1 - c0);
                hw_bus_cycles   = hw_bus_cycles + bc_r;
                hw_fetchw       = hw_fetchw + fw;
                hw_wbw          = hw_wbw + ww;
                if (gi == 0) hw_single_cycles = c1 - c0;
                if (gi == PEAK_IDX) begin
                    hw_peak_cycles = c1 - c0;
                    hw_peak_ticks  = mk;
                    hw_peak_disp   = dp;
                end
            end
        end
    endtask

    task load_mem;
        integer i;
        begin
            for (i = 0; i < MEMW; i = i + 1) mem[i] = init[i];
        end
    endtask

    task sweep_memory(input integer pass);
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < MEMW; i = i + 1) begin
                checks = checks + 1;
                if (mem[i] !== gold[i]) begin
                    mismatches = mismatches + 1;
                    bad = bad + 1;
                    if (shown < 40) begin
                        shown = shown + 1;
                        $display("MISMATCH memory word %0d (pass %0d): got %08x exp %08x",
                                 i, pass, mem[i], gold[i]);
                    end
                end
            end
            $display("  pass %0d: full-memory sweep over %0d words, %0d differences",
                     pass, MEMW, bad);
        end
    endtask

    // ================================================================= main
    integer gi, pass, fd, code, d;
    reg [31:0] tmp;

    initial begin
        cs_awvalid = 0; cs_wvalid = 0; cs_bready = 0;
        cs_arvalid = 0; cs_rready = 0; cs_awaddr = 0; cs_araddr = 0;
        cs_wdata = 0; cs_wstrb = 4'hF;
        hw_cycles_total = 0; hw_ticks_total = 0; hw_nodes_total = 0;
        hw_serial_total = 0; hw_peak_cycles = 0; hw_peak_ticks = 0;
        hw_bus_cycles = 0; hw_single_cycles = 0; hw_peak_disp = 0;
        hw_fetchw = 0; hw_wbw = 0;

        $readmemh("mem_init.hex",   init);
        $readmemh("golden_mem.hex", gold);

        fd = $fopen("graphs.txt", "r");
        if (fd == 0) begin $display("cannot open graphs.txt"); $finish; end
        for (gi = 0; gi < NG; gi = gi + 1) begin
            code = $fscanf(fd, "%s %d %d %d %d %d %d %d %d %d %d %d",
                           gname[gi], gn_cfg[gi], gn[gi], gnb[gi], grb[gi],
                           gerr[gi], gmk[gi], gdisp[gi], gstall[gi], gdw[gi],
                           gmc[gi], gser[gi]);
            if (code != 12) begin
                $display("graphs.txt: short read on line %0d (%0d fields)", gi, code);
                $display("TEST FAILED"); $finish;
            end
            for (d = 0; d < DEVICES; d = d + 1) begin
                code       = $fscanf(fd, "%d", tmp);
                gdb[gi][d] = tmp;
            end
        end
        $fclose(fd);

        $display("=========================================================");
        $display(" Day 18 - multi-GPU kernel-DAG scheduler");
        $display(" scoreboard %0d nodes, %0d devices, %0d words/node record",
                 MAX_NODES, DEVICES, NODE_WORDS);
        $display(" %0d graphs, memory image %0d words", NG, MEMW);
        $display("=========================================================");

        rst_n = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        csr_read(`KDS_A_CAPS, tmp);
        gi_cur = 0;
        chk("caps", tmp, (MAX_NODES << 8) | DEVICES);

        for (pass = 0; pass < 2; pass = pass + 1) begin
            ws_en = (pass == 0);
            load_mem;
            stall_cycles = 0;
            rd_beats = 0; wr_beats = 0;
            $display("--- pass %0d (%0s) -------------------------------------",
                     pass, (pass == 0) ? "randomised wait states" : "full rate");
            pass_begin[pass] = cycles;
            for (gi = 0; gi < NG; gi = gi + 1) run_graph(gi, pass);
            sweep_memory(pass);
            pass_cycles[pass] = cycles - pass_begin[pass];
            pass_stalls[pass] = stall_cycles;
            $display("  pass %0d: %0d read beats, %0d write beats, %0d bus stall cycles",
                     pass, rd_beats, wr_beats, stall_cycles);
        end

        // ================================================== directed extras
        ws_en = 0;
        gi_cur = 0;

        // ---- interrupt masking: status is sticky even with the enable clear
        csr_write(`KDS_A_IRQ_ENABLE, 32'h0);
        csr_write(`KDS_A_NUM_NODES,  gn_cfg[1]);
        csr_write(`KDS_A_NODE_BASE,  gnb[1]);
        csr_write(`KDS_A_RSLT_BASE,  grb[1]);
        csr_write(`KDS_A_CTRL, 32'h1);
        csr_read(`KDS_A_STATUS, st);
        while (st & 32'h1) csr_read(`KDS_A_STATUS, st);
        chk("masked_irq_line", {31'd0, irq}, 32'h0);
        csr_read(`KDS_A_IRQ_STATUS, ir);
        chk("masked_irq_sticky", ir, 32'h1);
        csr_write(`KDS_A_IRQ_STATUS, 32'h3);
        csr_write(`KDS_A_IRQ_ENABLE, 32'h3);
        $display("--- interrupt masking: line stays low, status stays sticky");

        // ---- unknown register reads as zero
        csr_read(12'h0FC, tmp);
        chk("unknown_reg", tmp, 32'h0);

        // ---- read SLVERR over a graph's node array -> E_BUS
        err_lo = gnb[1];
        err_hi = gnb[1] + gn[1]*NODE_WORDS*4 - 1;
        err_en = 1;
        csr_write(`KDS_A_NUM_NODES, gn_cfg[1]);
        csr_write(`KDS_A_NODE_BASE, gnb[1]);
        csr_write(`KDS_A_RSLT_BASE, grb[1]);
        csr_write(`KDS_A_CTRL, 32'h1);
        wait_irq(200000);
        csr_read(`KDS_A_STATUS, st);
        chk("read_slverr_code", (st >> 8) & 32'hF, `KDS_E_BUS);
        csr_read(`KDS_A_IRQ_STATUS, ir);
        chk("read_slverr_irq", ir, 32'h2);
        csr_write(`KDS_A_IRQ_STATUS, 32'h3);
        $display("--- read SLVERR on the graph fetch reported as E_BUS");

        // ---- write SLVERR over a graph's result array -> E_BUS
        err_lo = grb[1];
        err_hi = grb[1] + gn[1]*16 - 1;
        csr_write(`KDS_A_NUM_NODES, gn_cfg[1]);
        csr_write(`KDS_A_NODE_BASE, gnb[1]);
        csr_write(`KDS_A_RSLT_BASE, grb[1]);
        csr_write(`KDS_A_CTRL, 32'h1);
        wait_irq(200000);
        csr_read(`KDS_A_STATUS, st);
        chk("write_slverr_code", (st >> 8) & 32'hF, `KDS_E_BUS);
        csr_read(`KDS_A_MAKESPAN, tmp);
        chk("write_slverr_makespan", tmp, gmk[1]);   // the schedule still ran
        csr_write(`KDS_A_IRQ_STATUS, 32'h3);
        err_en = 0;
        $display("--- write SLVERR on the result writeback reported as E_BUS");

        // ---- recovery: the same graph runs cleanly straight afterwards
        load_mem;
        gi_cur = 1;
        run_graph(1, 2);
        $display("--- recovery after a bus fault: graph 1 re-ran cleanly");

        chk("no_oob", oob_hits, 32'h0);

        // ======================================================== summary
        $display("=========================================================");
        $display(" graphs per pass        : %0d (%0d clean, %0d error cases)",
                 NG, NG - err_count(), err_count());
        $display(" nodes scheduled / pass : %0d", hw_nodes_total);
        $display(" scheduler ticks / pass : %0d", hw_ticks_total);
        $display(" serial ticks / pass    : %0d", hw_serial_total);
        $display(" engine cycles (full rate, START to IRQ): %0d", hw_cycles_total);
        $display(" wait-state pass total cycles           : %0d", pass_cycles[0]);
        $display(" full-rate pass total cycles            : %0d", pass_cycles[1]);
        $display(" bus stall cycles (wait-state pass)     : %0d", pass_stalls[0]);
        $display(" bus phase cycles (fetch + writeback)   : %0d", hw_bus_cycles);
        $display(" bus words (fetch / writeback)          : %0d / %0d",
                 hw_fetchw, hw_wbw);
        $display(" single-node graph latency              : %0d cycles",
                 hw_single_cycles);
        $display(" peak graph cycles / ticks / dispatched : %0d / %0d / %0d",
                 hw_peak_cycles, hw_peak_ticks, hw_peak_disp);
        $display(" checks                 : %0d", checks);
        $display(" mismatches             : %0d", mismatches);
        $display("=========================================================");

        if (mismatches == 0) $display("TEST PASSED");
        else                 $display("TEST FAILED");
        $finish;
    end

    function integer err_count;
        integer i, c;
        begin
            c = 0;
            for (i = 0; i < NG; i = i + 1) if (gerr[i] != 0) c = c + 1;
            err_count = c;
        end
    endfunction

endmodule
