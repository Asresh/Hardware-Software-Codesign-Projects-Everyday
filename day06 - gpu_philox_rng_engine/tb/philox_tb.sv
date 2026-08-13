// -----------------------------------------------------------------------------
// philox_tb.sv
// Self-checking differential testbench for the Philox RNG engine.
//   * Models external device memory as a 32-bit-word array; the engine's
//     coalesced wide write beats land under a per-word write mask (so partial
//     final beats only touch real draws).
//   * Drives the MMIO mailbox as an in-testbench host: programs the descriptor
//     {DST,NDRAWS,KEY0,KEY1,CTR0..3}, rings the doorbell, waits on STATUS.DONE,
//     reads CYCLES, then compares the generated word stream against the software
//     golden ($readmemh). Mismatches must be 0.
//   * Aggregates hardware cycles and draw counts and reports peak and sustained
//     throughput plus the speedup over the scalar-baseline cost model.
//
// Geometry comes from tb/vectors/params.vh (written by philox_host); the job
// list comes from tb/vectors/jobs.txt at run time.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module philox_tb;
`include "params.vh"
    localparam integer MAX_JOBS = 4096;
    localparam integer MAX_WORD = 2400;      // >= largest golden stream

    localparam [7:0] REG_IDENT=8'h00, REG_CTRL=8'h04, REG_STATUS=8'h08,
        REG_DST=8'h0C, REG_NDRAWS=8'h10, REG_KEY0=8'h14, REG_KEY1=8'h18,
        REG_CTR0=8'h1C, REG_CTR1=8'h20, REG_CTR2=8'h24, REG_CTR3=8'h28,
        REG_CYCLES=8'h2C, REG_LANES=8'h30;
    localparam [31:0] CTRL_START=32'h1, CTRL_IRQ_EN=32'h2, CTRL_IRQ_CLR=32'h4;
    localparam [31:0] STATUS_DONE=32'h1, STATUS_BUSY=32'h2;

    // ---------------- clock / reset ----------------
    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;                        // 100 MHz

    // ---------------- MMIO master wires ----------------
    reg         mmio_sel, mmio_write;
    reg  [7:0]  mmio_addr;
    reg  [31:0] mmio_wdata;
    wire [31:0] mmio_rdata;

    // ---------------- wide write master wires ----------------
    wire                  mem_wr_en;
    wire [ADDR_WIDTH-1:0] mem_wr_addr;
    wire [WORD_W-1:0]     mem_wr_data;
    wire [WPB-1:0]        mem_wr_mask;
    wire                  irq;

    philox_top #(
        .LANES(LANES), .ROUNDS(ROUNDS), .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_sel(mmio_sel), .mmio_write(mmio_write), .mmio_addr(mmio_addr),
        .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data), .mem_wr_mask(mem_wr_mask),
        .irq(irq)
    );

    // ---------------- device memory model (masked wide write) ----------------
    reg [31:0] mem      [0:MEM_WORDS-1];
    reg [31:0] gold_mem [0:MAX_WORD-1];
    integer wi;
    always @(posedge clk) begin
        if (mem_wr_en) begin
            for (wi = 0; wi < WPB; wi = wi + 1)
                if (mem_wr_mask[wi])
                    mem[mem_wr_addr + wi] <= mem_wr_data[wi*32 +: 32];
        end
    end

    // ---------------- MMIO master tasks ----------------
    task mmio_write_reg(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            mmio_sel <= 1'b1; mmio_write <= 1'b1;
            mmio_addr <= addr; mmio_wdata <= data;
            @(posedge clk);
            mmio_sel <= 1'b0; mmio_write <= 1'b0;
        end
    endtask

    task mmio_read_reg(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            mmio_sel <= 1'b1; mmio_write <= 1'b0; mmio_addr <= addr;
            @(posedge clk);
            data = mmio_rdata;
            mmio_sel <= 1'b0;
        end
    endtask

    // ---------------- job manifest storage ----------------
    integer dst_a[0:MAX_JOBS-1], nd_a[0:MAX_JOBS-1], nw_a[0:MAX_JOBS-1];
    integer k0_a[0:MAX_JOBS-1], k1_a[0:MAX_JOBS-1];
    integer c0_a[0:MAX_JOBS-1], c1_a[0:MAX_JOBS-1];
    integer c2_a[0:MAX_JOBS-1], c3_a[0:MAX_JOBS-1];

    integer fd, r, j, i, njobs_f, lanes_f, aw_f;
    reg [31:0] rdv, cyc;
    integer job_mism, total_mism, total_checks;
    integer total_cyc, total_draws;
    integer peak_draws, peak_cyc, jratio, peak_ratio;
    integer wait_cnt;
    string  fname;

    initial begin
        mmio_sel=0; mmio_write=0; mmio_addr=0; mmio_wdata=0;
        $dumpfile("results/philox_tb.vcd");
        $dumpvars(0, philox_tb);

        total_mism=0; total_checks=0; total_cyc=0; total_draws=0;
        peak_draws=0; peak_cyc=0; peak_ratio=0;

        repeat (6) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // ---- identity check ----
        mmio_read_reg(REG_IDENT, rdv);
        if (rdv !== IDENT_VALUE) begin
            $display("FATAL: IDENT=%08x != %08x", rdv, IDENT_VALUE);
            $display("TEST FAILED"); $finish;
        end
        mmio_read_reg(REG_LANES, rdv);
        if (rdv !== LANES) begin
            $display("FATAL: LANES reg=%0d != %0d", rdv, LANES);
            $display("TEST FAILED"); $finish;
        end

        // ---- read manifest header ----
        fd = $fopen("tb/vectors/jobs.txt", "r");
        if (fd == 0) begin $display("FATAL: cannot open jobs.txt"); $display("TEST FAILED"); $finish; end
        r = $fscanf(fd, "%d %d %d\n", njobs_f, lanes_f, aw_f);
        if (r != 3) begin $display("FATAL: bad jobs.txt header r=%0d", r); $display("TEST FAILED"); $finish; end
        if (lanes_f!==LANES || aw_f!==ADDR_WIDTH) begin
            $display("FATAL: vector geometry (LANES=%0d A=%0d) != DUT", lanes_f, aw_f);
            $display("TEST FAILED"); $finish;
        end
        for (j = 0; j < njobs_f; j = j + 1) begin
            r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d\n",
                        i, dst_a[j], nd_a[j], k0_a[j], k1_a[j],
                        c0_a[j], c1_a[j], c2_a[j], c3_a[j], nw_a[j]);
            if (r != 10) begin $display("FATAL: bad job line %0d r=%0d", j, r); $display("TEST FAILED"); $finish; end
        end
        $fclose(fd);

        // ---- run every job ----
        for (j = 0; j < njobs_f; j = j + 1) begin
            fname = $sformatf("tb/vectors/gold_%03d.hex", j);
            $readmemh(fname, gold_mem, 0, nw_a[j] - 1);

            mmio_write_reg(REG_DST,    dst_a[j]);
            mmio_write_reg(REG_NDRAWS, nd_a[j]);
            mmio_write_reg(REG_KEY0,   k0_a[j]);
            mmio_write_reg(REG_KEY1,   k1_a[j]);
            mmio_write_reg(REG_CTR0,   c0_a[j]);
            mmio_write_reg(REG_CTR1,   c1_a[j]);
            mmio_write_reg(REG_CTR2,   c2_a[j]);
            mmio_write_reg(REG_CTR3,   c3_a[j]);
            mmio_write_reg(REG_CTRL,   CTRL_START | CTRL_IRQ_EN);

            wait_cnt = 0; rdv = 0;
            while ((rdv & STATUS_DONE) == 0) begin
                mmio_read_reg(REG_STATUS, rdv);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 2000000) begin
                    $display("FATAL: job %0d timed out (ndraws=%0d)", j, nd_a[j]);
                    $display("TEST FAILED"); $finish;
                end
            end
            mmio_read_reg(REG_CYCLES, cyc);
            if (irq !== 1'b1) begin
                $display("FATAL: job %0d completed but irq not asserted", j);
                $display("TEST FAILED"); $finish;
            end
            mmio_write_reg(REG_CTRL, CTRL_IRQ_CLR);

            // check the generated stream against the golden output
            job_mism = 0;
            for (i = 0; i < nw_a[j]; i = i + 1) begin
                if (mem[dst_a[j] + i] !== gold_mem[i]) begin
                    if (job_mism < 4)
                        $display("  MISMATCH job=%0d word=%0d got=%08x exp=%08x (ndraws=%0d)",
                                 j, i, mem[dst_a[j]+i], gold_mem[i], nd_a[j]);
                    job_mism = job_mism + 1;
                end
            end

            total_mism   = total_mism + job_mism;
            total_checks = total_checks + nw_a[j];
            total_cyc    = total_cyc + cyc;
            total_draws  = total_draws + nd_a[j];
            // peak = best sustained throughput (draws/cycle), scaled x100000
            jratio = (cyc > 0) ? (nd_a[j] * 100000) / cyc : 0;
            if (jratio > peak_ratio) begin
                peak_ratio = jratio; peak_draws = nd_a[j]; peak_cyc = cyc;
            end
        end

        // ---- report ----
        $display("----------------------------------------------------------");
        $display("JOBS %0d", njobs_f);
        $display("CHECKS %0d", total_checks);
        $display("MISMATCHES %0d", total_mism);
        $display("HW_CYCLES_TOTAL %0d", total_cyc);
        $display("DRAWS_TOTAL %0d", total_draws);
        $display("WORDS_TOTAL %0d", total_checks);
        $display("PEAK_DRAWS %0d", peak_draws);
        $display("PEAK_CYCLES %0d", peak_cyc);
        $display("----------------------------------------------------------");
        if (total_mism == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end
endmodule

`default_nettype wire
