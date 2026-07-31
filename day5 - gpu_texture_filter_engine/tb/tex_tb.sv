// -----------------------------------------------------------------------------
// tex_tb.sv
// Self-checking differential testbench for the bilinear texture-filter engine.
//   * Models external device memory as a 32-bit-word array with single-cycle
//     read latency, serving the engine's coalesced load and store beats.
//   * Drives the MMIO mailbox as an in-testbench host: programs the descriptor
//     {SRC,DST,SRC_W,SRC_H,DST_W,DST_H,SCALE_X,SCALE_Y}, rings the doorbell,
//     waits on STATUS.DONE, reads CYCLES, then compares the destination image
//     word-for-word against the software golden ($readmemh). Mismatches must be 0.
//   * Aggregates hardware cycles and output-pixel counts and reports peak and
//     sustained throughput plus the speedup over the scalar-baseline cost model.
//
// Geometry comes from tb/vectors/params.vh (written by tex_host); the job list
// comes from tb/vectors/jobs.txt at run time.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tex_tb;
`include "params.vh"
    localparam integer MAX_JOBS = 4096;
    localparam integer MAX_WORD = (WMAX/PPW) * WMAX;

    localparam [7:0] REG_IDENT=8'h00, REG_CTRL=8'h04, REG_STATUS=8'h08,
        REG_SRC=8'h0C, REG_DST=8'h10, REG_SRC_W=8'h14, REG_SRC_H=8'h18,
        REG_DST_W=8'h1C, REG_DST_H=8'h20, REG_SCALE_X=8'h24, REG_SCALE_Y=8'h28,
        REG_CYCLES=8'h2C;
    localparam [31:0] CTRL_START=32'h1, CTRL_IRQ_EN=32'h2, CTRL_IRQ_CLR=32'h4;
    localparam [31:0] STATUS_DONE=32'h1, STATUS_BUSY=32'h2;
    localparam [31:0] IDENT_VALUE=32'h5B170005;

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
    reg  [WORD_W-1:0]     mem_rd_data;
    wire                  mem_wr_en;
    wire [ADDR_WIDTH-1:0] mem_wr_addr;
    wire [WORD_W-1:0]     mem_wr_data;
    wire                  irq;

    tex_top #(
        .PIX_W(PIX_W), .PPW(PPW), .ADDR_WIDTH(ADDR_WIDTH),
        .WMAX(WMAX), .IDXW(IDXW)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_sel(mmio_sel), .mmio_write(mmio_write), .mmio_addr(mmio_addr),
        .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_data(mem_rd_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
        .irq(irq)
    );

    // ---------------- device memory model (single-cycle latency) ----------------
    reg [WORD_W-1:0] mem      [0:MEM_WORDS-1];
    reg [WORD_W-1:0] gold_mem [0:MAX_WORD-1];
    always @(posedge clk) begin
        if (mem_rd_en) mem_rd_data <= mem[mem_rd_addr];
        if (mem_wr_en) mem[mem_wr_addr] <= mem_wr_data;
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
    integer src_a[0:MAX_JOBS-1], dst_a[0:MAX_JOBS-1];
    integer sw_a [0:MAX_JOBS-1], sh_a [0:MAX_JOBS-1];
    integer dw_a [0:MAX_JOBS-1], dh_a [0:MAX_JOBS-1];
    integer scx_a[0:MAX_JOBS-1], scy_a[0:MAX_JOBS-1];
    integer nws_a[0:MAX_JOBS-1], nwd_a[0:MAX_JOBS-1];

    integer fd, r, j, i, njobs_f, pw_f, ppw_f, aw_f, wmax_f;
    reg [31:0] rdv, cyc;
    integer job_mism, total_mism, total_checks;
    integer total_cyc, total_pixels;
    integer peak_pix, peak_cyc, jpix, jratio, peak_ratio;
    integer wait_cnt;
    string  fname;

    initial begin
        mmio_sel=0; mmio_write=0; mmio_addr=0; mmio_wdata=0; mem_rd_data=0;
        $dumpfile("results/tex_tb.vcd");
        $dumpvars(0, tex_tb);

        total_mism=0; total_checks=0; total_cyc=0; total_pixels=0;
        peak_pix=0; peak_cyc=0; peak_ratio=0;

        repeat (6) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // ---- identity check ----
        mmio_read_reg(REG_IDENT, rdv);
        if (rdv !== IDENT_VALUE) begin
            $display("FATAL: IDENT=%08x != %08x", rdv, IDENT_VALUE);
            $display("TEST FAILED"); $finish;
        end

        // ---- read manifest header ----
        fd = $fopen("tb/vectors/jobs.txt", "r");
        if (fd == 0) begin $display("FATAL: cannot open jobs.txt"); $display("TEST FAILED"); $finish; end
        r = $fscanf(fd, "%d %d %d %d %d\n", njobs_f, pw_f, ppw_f, aw_f, wmax_f);
        if (r != 5) begin $display("FATAL: bad jobs.txt header r=%0d", r); $display("TEST FAILED"); $finish; end
        if (pw_f!==PIX_W || ppw_f!==PPW || aw_f!==ADDR_WIDTH || wmax_f!==WMAX) begin
            $display("FATAL: vector geometry (PIX_W=%0d PPW=%0d A=%0d WMAX=%0d) != DUT",
                     pw_f, ppw_f, aw_f, wmax_f);
            $display("TEST FAILED"); $finish;
        end
        for (j = 0; j < njobs_f; j = j + 1) begin
            r = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d\n",
                        i, src_a[j], dst_a[j], sw_a[j], sh_a[j], dw_a[j], dh_a[j],
                        scx_a[j], scy_a[j], nws_a[j], nwd_a[j]);
            if (r != 11) begin $display("FATAL: bad job line %0d r=%0d", j, r); $display("TEST FAILED"); $finish; end
        end
        $fclose(fd);

        // ---- run every job ----
        for (j = 0; j < njobs_f; j = j + 1) begin
            // load the source image and the golden output
            fname = $sformatf("tb/vectors/src_%03d.hex", j);
            $readmemh(fname, mem, src_a[j], src_a[j] + nws_a[j] - 1);
            fname = $sformatf("tb/vectors/gold_%03d.hex", j);
            $readmemh(fname, gold_mem, 0, nwd_a[j] - 1);

            // program the descriptor and ring the doorbell
            mmio_write_reg(REG_SRC,     src_a[j]);
            mmio_write_reg(REG_DST,     dst_a[j]);
            mmio_write_reg(REG_SRC_W,   sw_a[j]);
            mmio_write_reg(REG_SRC_H,   sh_a[j]);
            mmio_write_reg(REG_DST_W,   dw_a[j]);
            mmio_write_reg(REG_DST_H,   dh_a[j]);
            mmio_write_reg(REG_SCALE_X, scx_a[j]);
            mmio_write_reg(REG_SCALE_Y, scy_a[j]);
            mmio_write_reg(REG_CTRL,    CTRL_START | CTRL_IRQ_EN);

            // wait for completion
            wait_cnt = 0; rdv = 0;
            while ((rdv & STATUS_DONE) == 0) begin
                mmio_read_reg(REG_STATUS, rdv);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 2000000) begin
                    $display("FATAL: job %0d timed out (%0dx%0d -> %0dx%0d)",
                             j, sw_a[j], sh_a[j], dw_a[j], dh_a[j]);
                    $display("TEST FAILED"); $finish;
                end
            end
            mmio_read_reg(REG_CYCLES, cyc);
            mmio_write_reg(REG_CTRL, CTRL_IRQ_CLR);

            // check the destination image against the golden output
            job_mism = 0;
            for (i = 0; i < nwd_a[j]; i = i + 1) begin
                if (mem[dst_a[j] + i] !== gold_mem[i]) begin
                    if (job_mism < 4)
                        $display("  MISMATCH job=%0d word=%0d got=%08x exp=%08x (%0dx%0d->%0dx%0d)",
                                 j, i, mem[dst_a[j]+i], gold_mem[i],
                                 sw_a[j], sh_a[j], dw_a[j], dh_a[j]);
                    job_mism = job_mism + 1;
                end
            end

            jpix = dw_a[j] * dh_a[j];
            total_mism   = total_mism + job_mism;
            total_checks = total_checks + nwd_a[j];
            total_cyc    = total_cyc + cyc;
            total_pixels = total_pixels + jpix;
            // peak = best sustained throughput (pixels/cycle), scaled x100000
            jratio = (cyc > 0) ? (jpix * 100000) / cyc : 0;
            if (jratio > peak_ratio) begin
                peak_ratio = jratio; peak_pix = jpix; peak_cyc = cyc;
            end
        end

        // ---- report ----
        $display("----------------------------------------------------------");
        $display("JOBS %0d", njobs_f);
        $display("CHECKS %0d", total_checks);
        $display("MISMATCHES %0d", total_mism);
        $display("HW_CYCLES_TOTAL %0d", total_cyc);
        $display("PIXELS_TOTAL %0d", total_pixels);
        $display("PEAK_PIXELS %0d", peak_pix);
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
