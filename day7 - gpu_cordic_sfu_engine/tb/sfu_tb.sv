// -----------------------------------------------------------------------------
// sfu_tb.sv
// Self-checking differential testbench for the CORDIC SFU engine.
//   * Models external device memory as a 32-bit-word array with a coalesced
//     gather-read port (1-cycle latency) and a coalesced scatter-write port
//     under a per-lane write mask.
//   * Acts as the host: for each job it writes the request stream into the
//     submission ring at the descriptor's wrapped addresses, drives the MMIO
//     mailbox {REQ_BASE,RES_BASE,RING_CAP,REQ_HEAD,RES_HEAD,COUNT}, rings the
//     doorbell, waits on STATUS.DONE, reads CYCLES, then reads each result back
//     from the completion ring's wrapped address and compares (op,r0,r1) against
//     the software golden. Mismatches must be 0.
//   * Aggregates hardware cycles and request counts and reports peak and
//     sustained throughput plus the speedup over the scalar-baseline cost model.
//
// Geometry comes from tb/vectors/params.vh (written by sfu_host); the job list
// and per-job request/golden streams come from tb/vectors/ at run time.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module sfu_tb;
`include "params.vh"
    localparam integer MAX_JOBS  = 4096;
    localparam integer MAX_COUNT = 96;
    localparam integer MAX_REQW  = MAX_COUNT * ENTRY_WORDS;
    localparam integer MAX_GOLDW = MAX_COUNT * 3;

    localparam [7:0] REG_IDENT=8'h00, REG_CTRL=8'h04, REG_STATUS=8'h08,
        REG_REQ_BASE=8'h0C, REG_RES_BASE=8'h10, REG_RING_CAP=8'h14,
        REG_REQ_HEAD=8'h18, REG_RES_HEAD=8'h1C, REG_COUNT=8'h20,
        REG_CYCLES=8'h24, REG_LANES=8'h28;
    localparam [31:0] CTRL_START=32'h1, CTRL_IRQ_EN=32'h2, CTRL_IRQ_CLR=32'h4;
    localparam [31:0] STATUS_DONE=32'h1;

    // ---------------- clock / reset ----------------
    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;                          // 100 MHz

    // ---------------- MMIO master wires ----------------
    reg         mmio_sel, mmio_write;
    reg  [7:0]  mmio_addr;
    reg  [31:0] mmio_wdata;
    wire [31:0] mmio_rdata;

    // ---------------- memory master wires ----------------
    wire                     mem_rd_en;
    wire [LANES*ADDR_WIDTH-1:0] mem_rd_addr;
    wire [LANES-1:0]         mem_rd_mask;
    reg  [WORD_W-1:0]        mem_rd_data;
    wire                     mem_wr_en;
    wire [LANES*ADDR_WIDTH-1:0] mem_wr_addr;
    wire [LANES-1:0]         mem_wr_mask;
    wire [WORD_W-1:0]        mem_wr_data;
    wire                     irq;

    sfu_top #(
        .LANES(LANES), .ADDR_WIDTH(ADDR_WIDTH), .ENTRY_WORDS(ENTRY_WORDS),
        .ROMFILE("tb/vectors/cordic_rom.hex")
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_sel(mmio_sel), .mmio_write(mmio_write), .mmio_addr(mmio_addr),
        .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_mask(mem_rd_mask),
        .mem_rd_data(mem_rd_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr), .mem_wr_mask(mem_wr_mask),
        .mem_wr_data(mem_wr_data),
        .irq(irq)
    );

    // ---------------- device memory model ----------------
    reg [31:0] mem [0:MEM_WORDS-1];
    integer li, wj;
    reg [ADDR_WIDTH-1:0] la;

    // gather read: 1-cycle latency, per-lane 128-bit line (word j at addr+j)
    always @(posedge clk) begin
        if (mem_rd_en) begin
            for (li = 0; li < LANES; li = li + 1) begin
                if (mem_rd_mask[li]) begin
                    la = mem_rd_addr[li*ADDR_WIDTH +: ADDR_WIDTH];
                    for (wj = 0; wj < 4; wj = wj + 1)
                        mem_rd_data[li*128 + wj*32 +: 32] <= mem[la + wj];
                end
            end
        end
    end

    // scatter write: per-lane 4-word entry under lane mask
    always @(posedge clk) begin
        if (mem_wr_en) begin
            for (li = 0; li < LANES; li = li + 1) begin
                if (mem_wr_mask[li]) begin
                    la = mem_wr_addr[li*ADDR_WIDTH +: ADDR_WIDTH];
                    for (wj = 0; wj < 4; wj = wj + 1)
                        mem[la + wj] <= mem_wr_data[li*128 + wj*32 +: 32];
                end
            end
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
    integer rqb_a[0:MAX_JOBS-1], rsb_a[0:MAX_JOBS-1], cap_a[0:MAX_JOBS-1];
    integer rqh_a[0:MAX_JOBS-1], rsh_a[0:MAX_JOBS-1], cnt_a[0:MAX_JOBS-1];

    reg [31:0] reqflat  [0:MAX_REQW-1];
    reg [31:0] goldflat [0:MAX_GOLDW-1];

    integer fd, r, j, k, i, njobs_f, lanes_f, aw_f;
    integer idx, addr, capmask;
    reg [31:0] rdv, cyc;
    reg [31:0] got_op, got_r0, got_r1, got_pad;
    integer job_mism, total_mism, total_checks;
    integer total_cyc, total_req;
    integer peak_req, peak_cyc, jratio, peak_ratio;
    integer wait_cnt;
    string  fname;

    initial begin
        mmio_sel=0; mmio_write=0; mmio_addr=0; mmio_wdata=0; mem_rd_data=0;
        $dumpfile("results/sfu_tb.vcd");
        $dumpvars(0, sfu_tb);

        total_mism=0; total_checks=0; total_cyc=0; total_req=0;
        peak_req=0; peak_cyc=0; peak_ratio=0;

        repeat (6) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // ---- identity checks ----
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
            r = $fscanf(fd, "%d %d %d %d %d %d %d\n",
                        i, rqb_a[j], rsb_a[j], cap_a[j], rqh_a[j], rsh_a[j], cnt_a[j]);
            if (r != 7) begin $display("FATAL: bad job line %0d r=%0d", j, r); $display("TEST FAILED"); $finish; end
        end
        $fclose(fd);

        // ---- run every job ----
        for (j = 0; j < njobs_f; j = j + 1) begin
            capmask = cap_a[j] - 1;

            // load request + golden streams for this job
            fname = $sformatf("tb/vectors/req_%03d.hex", j);
            $readmemh(fname, reqflat, 0, cnt_a[j]*ENTRY_WORDS - 1);
            fname = $sformatf("tb/vectors/gold_%03d.hex", j);
            $readmemh(fname, goldflat, 0, cnt_a[j]*3 - 1);

            // host fills the submission ring (wrapped addresses); engine idle
            for (k = 0; k < cnt_a[j]; k = k + 1) begin
                idx  = (rqh_a[j] + k) & capmask;
                addr = rqb_a[j] + idx*ENTRY_WORDS;
                mem[addr + 0] = reqflat[k*ENTRY_WORDS + 0];
                mem[addr + 1] = reqflat[k*ENTRY_WORDS + 1];
                mem[addr + 2] = reqflat[k*ENTRY_WORDS + 2];
                mem[addr + 3] = 32'd0;
            end

            // program the ring descriptor and ring the doorbell
            mmio_write_reg(REG_REQ_BASE, rqb_a[j]);
            mmio_write_reg(REG_RES_BASE, rsb_a[j]);
            mmio_write_reg(REG_RING_CAP, cap_a[j]);
            mmio_write_reg(REG_REQ_HEAD, rqh_a[j]);
            mmio_write_reg(REG_RES_HEAD, rsh_a[j]);
            mmio_write_reg(REG_COUNT,    cnt_a[j]);
            mmio_write_reg(REG_CTRL,     CTRL_START | CTRL_IRQ_EN);

            wait_cnt = 0; rdv = 0;
            while ((rdv & STATUS_DONE) == 0) begin
                mmio_read_reg(REG_STATUS, rdv);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 2000000) begin
                    $display("FATAL: job %0d timed out (count=%0d)", j, cnt_a[j]);
                    $display("TEST FAILED"); $finish;
                end
            end
            mmio_read_reg(REG_CYCLES, cyc);
            if (irq !== 1'b1) begin
                $display("FATAL: job %0d completed but irq not asserted", j);
                $display("TEST FAILED"); $finish;
            end
            mmio_write_reg(REG_CTRL, CTRL_IRQ_CLR);

            // check each result from the completion ring (wrapped address)
            job_mism = 0;
            for (k = 0; k < cnt_a[j]; k = k + 1) begin
                idx  = (rsh_a[j] + k) & capmask;
                addr = rsb_a[j] + idx*ENTRY_WORDS;
                got_op  = mem[addr + 0];
                got_r0  = mem[addr + 1];
                got_r1  = mem[addr + 2];
                got_pad = mem[addr + 3];
                if (got_op  !== goldflat[k*3 + 0] ||
                    got_r0  !== goldflat[k*3 + 1] ||
                    got_r1  !== goldflat[k*3 + 2] ||
                    got_pad !== 32'd0) begin
                    if (job_mism < 4)
                        $display("  MISMATCH job=%0d req=%0d op=%0d got(%08x,%08x,%08x,%08x) exp(%08x,%08x,%08x,0)",
                                 j, k, goldflat[k*3+0],
                                 got_op, got_r0, got_r1, got_pad,
                                 goldflat[k*3+0], goldflat[k*3+1], goldflat[k*3+2]);
                    job_mism = job_mism + 1;
                end
            end

            total_mism   = total_mism + job_mism;
            total_checks = total_checks + cnt_a[j]*3;
            total_cyc    = total_cyc + cyc;
            total_req    = total_req + cnt_a[j];
            jratio = (cyc > 0) ? (cnt_a[j] * 100000) / cyc : 0;
            if (jratio > peak_ratio) begin
                peak_ratio = jratio; peak_req = cnt_a[j]; peak_cyc = cyc;
            end
        end

        // ---- report ----
        $display("----------------------------------------------------------");
        $display("JOBS %0d", njobs_f);
        $display("CHECKS %0d", total_checks);
        $display("MISMATCHES %0d", total_mism);
        $display("HW_CYCLES_TOTAL %0d", total_cyc);
        $display("REQUESTS_TOTAL %0d", total_req);
        $display("WORDS_TOTAL %0d", total_checks);
        $display("PEAK_REQUESTS %0d", peak_req);
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
