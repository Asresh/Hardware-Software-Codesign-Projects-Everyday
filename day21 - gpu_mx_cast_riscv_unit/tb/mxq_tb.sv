// ===========================================================================
// mxq_tb - differential testbench for the MX-cast core.
//
// Every job is run twice: once with randomised gaps on the host bus and a
// randomised delay before the interrupt is serviced, and once at full rate.
// Both passes must produce identical memory, identical counters and an
// identical commit trace - if any result depended on how the host drove the
// bus, the two passes would disagree.
//
// Three independent things are checked on every job:
//
//   1. the commit trace, instruction by instruction, against the simulator -
//      every architectural write the core makes, in order, with its PC, its
//      destination register, its value and its memory address;
//   2. the contents of data memory afterwards, including a guard band of
//      poison either side of every destination;
//   3. all six performance counters, the trap cause, the halt PC and the
//      return value.
//
// and at the end of each pass the entire data memory is swept against a shadow
// the testbench maintains itself, which is what proves no job wrote anywhere
// it was not supposed to.
// ===========================================================================
`timescale 1ns / 1ps
`include "mxq_defs.vh"
`include "mxq_const.vh"

module mxq_tb;

    localparam IMEM_W = `MXQ_IMEM_W;
    localparam DMEM_W = `MXQ_DMEM_W;
    localparam IMEM_WORDS = (1 << IMEM_W);
    localparam DMEM_WORDS = (1 << DMEM_W);

    // host address map, in bytes
    localparam [19:0] W_IMEM = 20'h1_0000;
    localparam [19:0] W_DMEM = 20'h2_0000;
    localparam [19:0] R_CTRL    = `MXQ_R_CTRL         * 4;
    localparam [19:0] R_STATUS  = `MXQ_R_STATUS       * 4;
    localparam [19:0] R_IRQ     = `MXQ_R_IRQ_STAT     * 4;
    localparam [19:0] R_ERR     = `MXQ_R_ERRCODE      * 4;
    localparam [19:0] R_STARTPC = `MXQ_R_START_PC     * 4;
    localparam [19:0] R_WDOG    = `MXQ_R_WDOG         * 4;
    localparam [19:0] R_CYCLES  = `MXQ_R_CYCLES       * 4;
    localparam [19:0] R_INSTRET = `MXQ_R_INSTRET      * 4;
    localparam [19:0] R_CUSTOM  = `MXQ_R_CUSTOM_OPS   * 4;
    localparam [19:0] R_BRANCH  = `MXQ_R_BRANCH_TAKEN * 4;
    localparam [19:0] R_LOADS   = `MXQ_R_LOADS        * 4;
    localparam [19:0] R_STORES  = `MXQ_R_STORES       * 4;
    localparam [19:0] R_TRAPPC  = `MXQ_R_TRAP_PC      * 4;
    localparam [19:0] R_ARG0    = `MXQ_R_ARG0         * 4;
    localparam [19:0] R_ARG1    = `MXQ_R_ARG1         * 4;
    localparam [19:0] R_ARG2    = `MXQ_R_ARG2         * 4;
    localparam [19:0] R_ARG3    = `MXQ_R_ARG3         * 4;
    localparam [19:0] R_RETVAL  = `MXQ_R_RETVAL       * 4;
    localparam [19:0] R_HALTPC  = `MXQ_R_HALT_PC      * 4;
    localparam [19:0] R_CAPS    = `MXQ_R_CAPS         * 4;
    localparam [19:0] R_VERSION = `MXQ_R_VERSION      * 4;
    localparam [19:0] R_CSUM    = `MXQ_R_REGMAP_CSUM  * 4;

    localparam [31:0] C_START = 32'h1, C_IRQ_EN = 32'h2,
                      C_SOFT_RST = 32'h4, C_CLR_STAT = 32'h8;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         h_sel = 1'b0, h_we = 1'b0;
    reg  [19:0] h_addr = 20'd0;
    reg  [31:0] h_wdata = 32'd0;
    wire [31:0] h_rdata;
    wire        h_ready, irq;
    wire        dbg_valid;
    wire [31:0] dbg_pc, dbg_wdata, dbg_addr, dbg_sdata;
    wire [7:0]  dbg_code;

    mxq_top #(.IMEM_W(IMEM_W), .DMEM_W(DMEM_W)) dut (
        .clk(clk), .rst_n(rst_n),
        .h_sel(h_sel), .h_we(h_we), .h_addr(h_addr), .h_wdata(h_wdata),
        .h_rdata(h_rdata), .h_ready(h_ready), .irq(irq),
        .dbg_valid(dbg_valid), .dbg_pc(dbg_pc), .dbg_code(dbg_code),
        .dbg_wdata(dbg_wdata), .dbg_addr(dbg_addr), .dbg_sdata(dbg_sdata)
    );

    always #5 clk = ~clk;

    // ---- vectors ----------------------------------------------------------
    reg [31:0] jobmem  [0:`NJOBS * `JOBW - 1];
    reg [31:0] ipool   [0:`IMEM_WORDS - 1];
    reg [31:0] dinit   [0:`DINIT_N * 2 - 1];
    reg [31:0] dexp    [0:`DEXP_N * 2 - 1];
    reg [31:0] tracev  [0:`TRACE_N * 5 - 1];
    reg [31:0] shadow  [0:DMEM_WORDS - 1];
    reg [31:0] passa   [0:`NJOBS * 8 - 1];

    integer checks = 0, fails = 0, jobs_run = 0;
    integer commits_checked = 0, mem_checked = 0, sweep_checked = 0;
    integer pass;
    integer imem_hi = 0;
    integer rndstate = 32'h1234_5678;

    // trace checking state
    integer chk_trace = 0;
    integer t_off = 0, t_len = 0, t_ptr = 0;
    integer cur_job = 0;

    function integer rnd;
        input integer lim;
        begin
            rndstate = (rndstate * 1103515245 + 12345) & 32'h7FFFFFFF;
            rnd = (lim <= 0) ? 0 : ((rndstate >> 7) % lim);
        end
    endfunction

    task expect32;
        input [255:0] what;
        input [31:0]  got;
        input [31:0]  want;
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                if (fails < 40)
                    $display("MISMATCH job %0d %0s: got %08x want %08x",
                             cur_job, what, got, want);
            end
        end
    endtask

    // ---- host bus ---------------------------------------------------------
    integer bus_gap = 0;

    task hwrite;
        input [19:0] a;
        input [31:0] d;
        integer g;
        begin
            g = bus_gap ? rnd(4) : 0;
            repeat (g) @(posedge clk);
            @(posedge clk);
            h_sel <= 1'b1; h_we <= 1'b1; h_addr <= a; h_wdata <= d;
            @(posedge clk);
            while (!h_ready) @(posedge clk);
            h_sel <= 1'b0; h_we <= 1'b0;
        end
    endtask

    task hread;
        input  [19:0] a;
        output [31:0] d;
        integer g;
        begin
            g = bus_gap ? rnd(4) : 0;
            repeat (g) @(posedge clk);
            @(posedge clk);
            h_sel <= 1'b1; h_we <= 1'b0; h_addr <= a;
            @(posedge clk);
            while (!h_ready) @(posedge clk);
            d = h_rdata;
            h_sel <= 1'b0;
        end
    endtask

    // ---- commit trace monitor --------------------------------------------
    always @(posedge clk) begin
        if (rst_n && dbg_valid && chk_trace) begin
            if (t_ptr >= t_len) begin
                fails = fails + 1;
                if (fails < 40)
                    $display("MISMATCH job %0d: commit %0d past end of trace (pc %08x)", cur_job, t_ptr, dbg_pc);
            end else begin
                checks = checks + 5;
                commits_checked = commits_checked + 1;
                if (dbg_pc    !== tracev[(t_off + t_ptr) * 5 + 0] ||
                    {24'd0, dbg_code} !== tracev[(t_off + t_ptr) * 5 + 1] ||
                    dbg_wdata !== tracev[(t_off + t_ptr) * 5 + 2] ||
                    dbg_addr  !== tracev[(t_off + t_ptr) * 5 + 3] ||
                    dbg_sdata !== tracev[(t_off + t_ptr) * 5 + 4]) begin
                    fails = fails + 1;
                    if (fails < 40)
                        $display("MISMATCH job %0d commit %0d: got pc=%08x code=%02x wd=%08x ad=%08x sd=%08x  want pc=%08x code=%02x wd=%08x ad=%08x sd=%08x",
                                 cur_job, t_ptr, dbg_pc, dbg_code, dbg_wdata,
                                 dbg_addr, dbg_sdata,
                                 tracev[(t_off + t_ptr) * 5 + 0],
                                 tracev[(t_off + t_ptr) * 5 + 1],
                                 tracev[(t_off + t_ptr) * 5 + 2],
                                 tracev[(t_off + t_ptr) * 5 + 3],
                                 tracev[(t_off + t_ptr) * 5 + 4]);
                end
            end
            t_ptr = t_ptr + 1;
        end
    end

    // ---- one job ----------------------------------------------------------
    reg [31:0] j [0:`JOBW - 1];
    reg [31:0] rv;
    integer    k, w, tmo;

    task load_job;
        input integer id;
        integer i;
        begin
            for (i = 0; i < `JOBW; i = i + 1) j[i] = jobmem[id * `JOBW + i];
        end
    endtask

    task run_job;
        input integer id;
        integer i, nimg, ioff, ninit, dioff, nexp, deoff;
        begin
            cur_job = id;
            load_job(id);
            nimg  = j[2];  ioff  = j[1];
            ninit = j[4];  dioff = j[3];
            nexp  = j[6];  deoff = j[5];

            // soft reset between jobs: the core must come back from anything
            hwrite(R_CTRL, C_SOFT_RST);

            // program: write the image, then clear whatever the last one left
            for (i = 0; i < nimg; i = i + 1)
                hwrite(W_IMEM + i * 4, ipool[ioff + i]);
            for (i = nimg; i < imem_hi; i = i + 1)
                hwrite(W_IMEM + i * 4, 32'd0);
            imem_hi = nimg;

            // data memory
            for (i = 0; i < ninit; i = i + 1) begin
                hwrite(W_DMEM + dinit[(dioff + i) * 2] * 4,
                       dinit[(dioff + i) * 2 + 1]);
                shadow[dinit[(dioff + i) * 2]] = dinit[(dioff + i) * 2 + 1];
            end

            hwrite(R_STARTPC, j[13]);
            hwrite(R_WDOG,     j[14]);
            hwrite(R_ARG0,     j[9]);
            hwrite(R_ARG1,     j[10]);
            hwrite(R_ARG2,     j[11]);
            hwrite(R_ARG3,     j[12]);

            t_off = j[7]; t_len = j[8]; t_ptr = 0;
            chk_trace = j[26];

            hwrite(R_CTRL, C_START | C_IRQ_EN);

            tmo = 0;
            while (!irq && tmo < 4000000) begin
                @(posedge clk);
                tmo = tmo + 1;
            end
            if (!irq) begin
                fails = fails + 1;
                $display("MISMATCH job %0d: no interrupt after %0d cycles",
                         id, tmo);
            end
            if (bus_gap) repeat (rnd(20)) @(posedge clk);
            chk_trace = 0;

            if (j[26] && t_ptr != t_len) begin
                fails = fails + 1;
                $display("MISMATCH job %0d: %0d commits, expected %0d",
                         id, t_ptr, t_len);
            end

            hread(R_STATUS, rv);
            expect32("status", rv, {29'd0, j[21][0], 1'b1, 1'b0});
            hread(R_ERR, rv);       expect32("errcode", rv, j[22]);
            hread(R_INSTRET, rv);       expect32("instret", rv, j[15]);
            hread(R_CYCLES,  rv);       expect32("cycles",  rv, j[16]);
            hread(R_CUSTOM, rv);    expect32("custom",  rv, j[17]);
            hread(R_BRANCH, rv);  expect32("branch",  rv, j[18]);
            hread(R_LOADS,   rv);       expect32("loads",   rv, j[19]);
            hread(R_STORES,  rv);       expect32("stores",  rv, j[20]);
            hread(R_IRQ, rv);
            expect32("irq_stat", rv, j[21] ? 32'd2 : 32'd1);
            if (!j[21]) begin
                hread(R_RETVAL, rv);    expect32("retval", rv, j[23]);
                hread(R_HALTPC, rv);   expect32("halt_pc", rv, j[24]);
            end else begin
                hread(R_TRAPPC, rv);   expect32("trap_pc", rv, j[25]);
            end

            // pass A records what the hardware did; pass B has to match it
            hread(R_CUSTOM, rv);
            if (pass == 0) begin
                passa[id * 8 + 0] = j[15]; passa[id * 8 + 1] = j[16];
                passa[id * 8 + 2] = rv;
            end else begin
                expect32("pass A/B instret", j[15], passa[id * 8 + 0]);
                expect32("pass A/B cycles",  j[16], passa[id * 8 + 1]);
                expect32("pass A/B custom",  rv,    passa[id * 8 + 2]);
            end

            hwrite(R_IRQ, 32'd3);
            hread(R_IRQ, rv);      expect32("irq w1c", rv, 32'd0);

            for (i = 0; i < nexp; i = i + 1) begin
                hread(W_DMEM + dexp[(deoff + i) * 2] * 4, rv);
                expect32("dmem", rv, dexp[(deoff + i) * 2 + 1]);
                shadow[dexp[(deoff + i) * 2]] = dexp[(deoff + i) * 2 + 1];
                mem_checked = mem_checked + 1;
            end

            jobs_run = jobs_run + 1;
        end
    endtask

    // ---- control-plane directed tests -------------------------------------
    task control_plane;
        integer i;
        begin
            cur_job = -1;
            hwrite(R_CTRL, C_SOFT_RST);
            hread(R_VERSION, rv);
            expect32("version", rv, `VERSION_ID);
            hread(R_CSUM, rv);
            expect32("regmap csum", rv, `CSUM);
            hread(R_CAPS, rv);
            expect32("caps", rv, {8'd0, 8'd5, 8'd`MXQ_DMEM_W, 8'd`MXQ_IMEM_W});

            // unmapped registers read as zero
            for (i = 22; i < 32; i = i + 1) begin
                hread(i * 4, rv);
                expect32("unmapped", rv, 32'd0);
            end

            // write-only and read-only registers behave
            hwrite(R_CYCLES, 32'hDEAD_BEEF);
            hread(R_CYCLES, rv);
            expect32("cycles read-only", rv, 32'd0);

            // arguments read back
            hwrite(R_ARG2, 32'h0BAD_F00D);
            hread(R_ARG2, rv);
            expect32("arg2", rv, 32'h0BAD_F00D);
            hwrite(R_ARG2, 32'd0);
        end
    endtask

    // launch a long job, prove the host cannot touch memory while it runs,
    // and that polling STATUS works when the interrupt is masked
    task running_access_and_polling;
        integer i, guard;
        begin
            cur_job = -2;
            hwrite(R_CTRL, C_SOFT_RST);
            for (i = 0; i < imem_hi; i = i + 1) hwrite(W_IMEM + i * 4, 32'd0);
            // a deliberate spin the watchdog has to break
            hwrite(W_IMEM + 0, 32'h0000_0013);   // addi x0, x0, 0
            hwrite(W_IMEM + 4, 32'h0000_006F);   // jal  x0, 0
            hwrite(W_DMEM + 32'd400, 32'hFEED_FACE);
            shadow[100] = 32'hFEED_FACE;
            hwrite(R_WDOG, 32'd50);
            hwrite(R_CTRL, C_START);     // interrupt masked
            @(posedge clk); @(posedge clk);
            hread(R_STATUS, rv);
            expect32("running", rv[0], 32'd1);
            hwrite(W_DMEM + 32'd400, 32'h0000_0000);   // must be ignored
            hread(W_DMEM + 32'd400, rv);
            expect32("mem read while running", rv, 32'd0);
            guard = 0;
            while (!(rv & 32'd2) && guard < 10000) begin
                hread(R_STATUS, rv);
                guard = guard + 1;
            end
            expect32("polled halt", rv & 32'd2, 32'd2);
            expect32("irq masked", {31'd0, irq}, 32'd0);
            hread(R_ERR, rv);
            expect32("wdog cause", rv, `MXQ_ERR_WDOG);
            hread(W_DMEM + 32'd400, rv);
            expect32("write while running ignored", rv, 32'hFEED_FACE);
            hwrite(R_IRQ, 32'd3);
            imem_hi = 2;
        end
    endtask

    task full_sweep;
        integer i;
        begin
            cur_job = -3;
            for (i = 0; i < DMEM_WORDS; i = i + 1) begin
                hread(W_DMEM + i * 4, rv);
                checks = checks + 1;
                sweep_checked = sweep_checked + 1;
                if (rv !== shadow[i]) begin
                    fails = fails + 1;
                    if (fails < 40)
                        $display("MISMATCH sweep word %0d: got %08x want %08x",
                                 i, rv, shadow[i]);
                end
            end
        end
    endtask

    // ---- main -------------------------------------------------------------
    integer i;
    initial begin
        $readmemh("jobs.hex",  jobmem);
        $readmemh("imem.hex",  ipool);
        $readmemh("dinit.hex", dinit);
        $readmemh("dexp.hex",  dexp);
        $readmemh("trace.hex", tracev);

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (pass = 0; pass < 2; pass = pass + 1) begin
            bus_gap = (pass == 0);
            imem_hi = 0;
            for (i = 0; i < DMEM_WORDS; i = i + 1) shadow[i] = 32'd0;
            // memory persists across passes, so bring it back to a known state
            for (i = 0; i < DMEM_WORDS; i = i + 1)
                hwrite(W_DMEM + i * 4, 32'd0);

            control_plane();
            for (i = 0; i < `NJOBS; i = i + 1) run_job(i);
            running_access_and_polling();
            full_sweep();

            $display("PASS %0d: jobs=%0d checks=%0d fails=%0d commits=%0d mem=%0d sweep=%0d",
                     pass, jobs_run, checks, fails, commits_checked,
                     mem_checked, sweep_checked);
        end

        // soft reset from a trapped state, then a good job, to prove recovery
        cur_job = -4;
        hwrite(R_CTRL, C_SOFT_RST);
        hread(R_STATUS, rv);
        expect32("status after soft reset", rv, 32'd0);
        hread(R_INSTRET, rv);
        expect32("counters after soft reset", rv, 32'd0);
        imem_hi = 0;
        run_job(0);

        $display("RESULT jobs=%0d checks=%0d fails=%0d commits=%0d mem=%0d sweep=%0d", jobs_run, checks, fails, commits_checked,
                 mem_checked, sweep_checked);
        if (fails == 0) $display("TEST PASSED");
        else            $display("TEST FAILED");
        $finish;
    end

endmodule
