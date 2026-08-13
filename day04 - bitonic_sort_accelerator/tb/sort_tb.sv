// -----------------------------------------------------------------------------
// sort_tb.sv
// Self-checking differential testbench for the tiled bitonic sort accelerator.
//   * Models external device memory as a wide, single-cycle-latency array that
//     serves the engine's coalesced read/write beats (one beat = one N-key tile).
//   * Drives the MMIO control plane as an in-testbench master.
//   * For every job: loads the source image, programs the descriptor
//     {SRC, DST, NTILES, MODE}, pulses START, waits for DONE, reads CYCLES, then
//     compares the destination region word-for-word against the software golden
//     ($readmemh). Mismatches must be zero.
//   * Aggregates hardware cycles / tile counts and reports peak and sustained
//     throughput and the speedup over the scalar-baseline cycle model.
//
// Geometry comes from tb/vectors/params.vh (written by sort_host); the job list
// comes from tb/vectors/jobs.txt at run time.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module sort_tb;
`include "params.vh"
    localparam integer MAX_JOBS = 1024;

    localparam [7:0] REG_IDENT=8'h00, REG_CTRL=8'h04, REG_STATUS=8'h08,
        REG_SRC=8'h0C, REG_DST=8'h10, REG_NTILES=8'h14, REG_MODE=8'h18,
        REG_CYCLES=8'h1C;
    localparam [31:0] CTRL_START=32'h1, CTRL_IRQ_EN=32'h2, CTRL_IRQ_CLR=32'h4;
    localparam [31:0] STATUS_DONE=32'h1, STATUS_BUSY=32'h2;
    localparam [31:0] IDENT_VALUE=32'h5B170004;

    // ---------------- clock / reset ----------------
    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;                        // 100 MHz

    // ---------------- MMIO master wires ----------------
    reg         mmio_sel, mmio_write;
    reg  [7:0]  mmio_addr;
    reg  [31:0] mmio_wdata;
    wire [31:0] mmio_rdata;

    // ---------------- wide memory master wires ----------------
    wire                  mem_rd_en;
    wire [ADDR_WIDTH-1:0] mem_rd_addr;
    reg  [N*W-1:0]        mem_rd_data;
    wire                  mem_wr_en;
    wire [ADDR_WIDTH-1:0] mem_wr_addr;
    wire [N*W-1:0]        mem_wr_data;
    wire                  irq;

    sort_top #(
        .N(N), .W(W), .ADDR_WIDTH(ADDR_WIDTH), .TILE_WIDTH(TILE_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_sel(mmio_sel), .mmio_write(mmio_write), .mmio_addr(mmio_addr),
        .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_data(mem_rd_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
        .irq(irq)
    );

    // ---------------- device memory model ----------------
    localparam integer MAX_KEYS = 4096;
    reg [W-1:0] mem      [0:MEM_WORDS-1];
    reg [W-1:0] gold_mem [0:MAX_KEYS-1];
    integer m;
    always @(posedge clk) begin
        if (mem_rd_en)
            for (m = 0; m < N; m = m + 1)
                mem_rd_data[m*W +: W] <= mem[mem_rd_addr + m[ADDR_WIDTH-1:0]];
        if (mem_wr_en)
            for (m = 0; m < N; m = m + 1)
                mem[mem_wr_addr + m[ADDR_WIDTH-1:0]] <= mem_wr_data[m*W +: W];
    end

    // ---------------- MMIO master tasks ----------------
    task mmio_write_reg(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            mmio_sel <= 1'b1; mmio_write <= 1'b1;
            mmio_addr <= addr; mmio_wdata <= data;   // commits on the next edge
            @(posedge clk);
            mmio_sel <= 1'b0; mmio_write <= 1'b0;
        end
    endtask

    task mmio_read_reg(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            mmio_sel <= 1'b1; mmio_write <= 1'b0; mmio_addr <= addr;
            @(posedge clk);
            data = mmio_rdata;                        // combinational read mux
            mmio_sel <= 1'b0;
        end
    endtask

    // ---------------- job manifest storage ----------------
    integer src_arr [0:MAX_JOBS-1];
    integer dst_arr [0:MAX_JOBS-1];
    integer nt_arr  [0:MAX_JOBS-1];
    integer mode_arr[0:MAX_JOBS-1];
    integer nw_arr  [0:MAX_JOBS-1];

    integer fd, r, j, i, njobs_f, n_f, w_f, aw_f, tw_f;
    reg [31:0] rdv, cyc;
    integer job_mism, total_mism, total_checks;
    integer total_cyc, total_tiles;
    integer peak_nw, peak_cyc;
    integer wait_cnt;
    string  fname;

    initial begin
        mmio_sel=0; mmio_write=0; mmio_addr=0; mmio_wdata=0; mem_rd_data=0;
        $dumpfile("results/sort_tb.vcd");
        $dumpvars(0, sort_tb);

        total_mism=0; total_checks=0; total_cyc=0; total_tiles=0;
        peak_nw=0; peak_cyc=0;

        repeat (6) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // ---- identity check ----
        mmio_read_reg(REG_IDENT, rdv);
        if (rdv !== IDENT_VALUE) begin
            $display("FATAL: IDENT=%08x != %08x", rdv, IDENT_VALUE);
            $display("TEST FAILED");
            $finish;
        end

        // ---- read manifest header ----
        fd = $fopen("tb/vectors/jobs.txt", "r");
        if (fd == 0) begin $display("FATAL: cannot open jobs.txt"); $display("TEST FAILED"); $finish; end
        r = $fscanf(fd, "%d %d %d %d %d\n", njobs_f, n_f, w_f, aw_f, tw_f);
        if (r != 5) begin $display("FATAL: bad jobs.txt header r=%0d", r); $display("TEST FAILED"); $finish; end
        if (n_f!==N || w_f!==W || aw_f!==ADDR_WIDTH || tw_f!==TILE_WIDTH) begin
            $display("FATAL: vector geometry (N=%0d W=%0d A=%0d TW=%0d) != DUT (N=%0d W=%0d A=%0d TW=%0d)",
                     n_f, w_f, aw_f, tw_f, N, W, ADDR_WIDTH, TILE_WIDTH);
            $display("TEST FAILED"); $finish;
        end
        for (j = 0; j < njobs_f; j = j + 1) begin
            r = $fscanf(fd, "%d %d %d %d %d %d\n",
                        i, src_arr[j], dst_arr[j], nt_arr[j], mode_arr[j], nw_arr[j]);
            if (r != 6) begin $display("FATAL: bad job line %0d r=%0d", j, r); $display("TEST FAILED"); $finish; end
        end
        $fclose(fd);

        // ---- run every job ----
        for (j = 0; j < njobs_f; j = j + 1) begin
            // load the source image into device memory at its base address
            if (nw_arr[j] > 0) begin
                fname = $sformatf("tb/vectors/src_%03d.hex", j);
                $readmemh(fname, mem, src_arr[j], src_arr[j] + nw_arr[j] - 1);
                fname = $sformatf("tb/vectors/gold_%03d.hex", j);
                $readmemh(fname, gold_mem, 0, nw_arr[j] - 1);
            end

            // program the descriptor and launch
            mmio_write_reg(REG_SRC,    src_arr[j]);
            mmio_write_reg(REG_DST,    dst_arr[j]);
            mmio_write_reg(REG_NTILES, nt_arr[j]);
            mmio_write_reg(REG_MODE,   mode_arr[j]);
            mmio_write_reg(REG_CTRL,   CTRL_START | CTRL_IRQ_EN);

            // wait for completion
            wait_cnt = 0;
            rdv = 0;
            while ((rdv & STATUS_DONE) == 0) begin
                mmio_read_reg(REG_STATUS, rdv);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 200000) begin
                    $display("FATAL: job %0d timed out (ntiles=%0d)", j, nt_arr[j]);
                    $display("TEST FAILED"); $finish;
                end
            end
            mmio_read_reg(REG_CYCLES, cyc);
            mmio_write_reg(REG_CTRL, CTRL_IRQ_CLR);

            // check the destination region against the golden image
            job_mism = 0;
            for (i = 0; i < nw_arr[j]; i = i + 1) begin
                if (mem[dst_arr[j] + i] !== gold_mem[i]) begin
                    if (job_mism < 4)
                        $display("  MISMATCH job=%0d i=%0d got=%08x exp=%08x (ntiles=%0d mode=%0d)",
                                 j, i, mem[dst_arr[j] + i], gold_mem[i], nt_arr[j], mode_arr[j]);
                    job_mism = job_mism + 1;
                end
            end

            total_mism   = total_mism + job_mism;
            total_checks = total_checks + nw_arr[j];
            total_cyc    = total_cyc + cyc;
            total_tiles  = total_tiles + nt_arr[j];
            if (nw_arr[j] > peak_nw) begin
                peak_nw  = nw_arr[j];
                peak_cyc = cyc;
            end
        end

        // ---- report ----
        $display("----------------------------------------------------------");
        $display("JOBS %0d", njobs_f);
        $display("CHECKS %0d", total_checks);
        $display("MISMATCHES %0d", total_mism);
        $display("HW_CYCLES_TOTAL %0d", total_cyc);
        $display("TILES_TOTAL %0d", total_tiles);
        $display("KEYS_TOTAL %0d", total_checks);
        $display("PEAK_KEYS %0d", peak_nw);
        $display("PEAK_CYCLES %0d", peak_cyc);
        $display("N %0d", N);
        $display("----------------------------------------------------------");
        if (total_mism == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end
endmodule

`default_nettype wire
