// -----------------------------------------------------------------------------
// scan_tb.sv
// Self-checking differential testbench for the parallel prefix-sum engine.
//   * Models external device memory as a wide, single-cycle-latency array that
//     serves the engine's coalesced read/write beats.
//   * Drives the APB control plane as an in-testbench master.
//   * For every job: loads the source image, programs the descriptor
//     {SRC, DST, LEN, MODE}, pulses START, waits for DONE, reads CYCLES, then
//     compares the destination region word-for-word against the software golden
//     ($readmemh). Mismatches must be zero.
//   * Aggregates hardware cycles / element counts and reports peak and sustained
//     throughput and the speedup over the scalar-baseline cycle model.
//
// Geometry comes from tb/vectors/params.vh (written by scan_host); the job list
// comes from tb/vectors/jobs.txt at run time.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module scan_tb;
`include "params.vh"
    localparam integer LANE_BITS = 5;          // holds 0..LANES for LANES<=16
    localparam integer MAX_JOBS  = 1024;

    localparam [7:0] REG_IDENT=8'h00, REG_CTRL=8'h04, REG_STATUS=8'h08,
        REG_SRC=8'h0C, REG_DST=8'h10, REG_LEN=8'h14, REG_MODE=8'h18,
        REG_CYCLES=8'h1C;
    localparam [31:0] CTRL_START=32'h1, CTRL_IRQ_EN=32'h2, CTRL_IRQ_CLR=32'h4;
    localparam [31:0] STATUS_DONE=32'h1, STATUS_BUSY=32'h2;
    localparam [31:0] IDENT_VALUE=32'h5CA40003;

    // ---------------- clock / reset ----------------
    reg clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;                        // 100 MHz

    // ---------------- APB master wires ----------------
    reg         psel, penable, pwrite;
    reg  [7:0]  paddr;
    reg  [31:0] pwdata;
    wire [31:0] prdata;
    wire        pready;

    // ---------------- wide memory master wires ----------------
    wire                  mem_rd_en;
    wire [ADDR_WIDTH-1:0] mem_rd_addr;
    reg  [LANES*W-1:0]    mem_rd_data;
    wire                  mem_wr_en;
    wire [ADDR_WIDTH-1:0] mem_wr_addr;
    wire [LANES*W-1:0]    mem_wr_data;
    wire [LANES-1:0]      mem_wr_be;
    wire                  irq;

    scan_top #(
        .LANES(LANES), .W(W), .ADDR_WIDTH(ADDR_WIDTH), .LEN_WIDTH(LEN_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata), .prdata(prdata), .pready(pready),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_data(mem_rd_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data), .mem_wr_be(mem_wr_be),
        .irq(irq)
    );

    // ---------------- device memory model ----------------
    reg [W-1:0] mem      [0:MEM_WORDS-1];
    reg [W-1:0] gold_mem [0:MEM_WORDS-1];
    integer m;
    always @(posedge clk) begin
        if (mem_rd_en)
            for (m = 0; m < LANES; m = m + 1)
                mem_rd_data[m*W +: W] <= mem[mem_rd_addr + m[ADDR_WIDTH-1:0]];
        if (mem_wr_en)
            for (m = 0; m < LANES; m = m + 1)
                if (mem_wr_be[m])
                    mem[mem_wr_addr + m[ADDR_WIDTH-1:0]] <= mem_wr_data[m*W +: W];
    end

    // ---------------- APB master tasks ----------------
    task apb_write(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            psel <= 1'b1; penable <= 1'b0; pwrite <= 1'b1;
            paddr <= addr; pwdata <= data;      // SETUP
            @(posedge clk);
            penable <= 1'b1;                     // ACCESS
            @(posedge clk);
            while (!pready) @(posedge clk);
            psel <= 1'b0; penable <= 1'b0; pwrite <= 1'b0;
        end
    endtask

    task apb_read(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            psel <= 1'b1; penable <= 1'b0; pwrite <= 1'b0;
            paddr <= addr;                        // SETUP
            @(posedge clk);
            penable <= 1'b1;                       // ACCESS
            @(posedge clk);
            while (!pready) @(posedge clk);
            data = prdata;
            psel <= 1'b0; penable <= 1'b0;
        end
    endtask

    // ---------------- job manifest storage ----------------
    integer src_arr [0:MAX_JOBS-1];
    integer dst_arr [0:MAX_JOBS-1];
    integer len_arr [0:MAX_JOBS-1];
    integer mode_arr[0:MAX_JOBS-1];
    integer pad_arr [0:MAX_JOBS-1];

    integer fd, r, j, i, njobs_f, lanes_f, w_f, aw_f, lw_f, idx;
    reg [31:0] rdv, cyc;
    integer job_mism, total_mism, total_checks;
    integer total_cyc, total_elems;
    integer peak_len, peak_cyc;
    integer wait_cnt;
    string  fname;

    initial begin
        psel=0; penable=0; pwrite=0; paddr=0; pwdata=0; mem_rd_data=0;
        $dumpfile("results/scan_tb.vcd");
        $dumpvars(0, scan_tb);

        total_mism=0; total_checks=0; total_cyc=0; total_elems=0;
        peak_len=0; peak_cyc=0;

        repeat (6) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        // ---- identity check ----
        apb_read(REG_IDENT, rdv);
        if (rdv !== IDENT_VALUE) begin
            $display("FATAL: IDENT=%08x != %08x", rdv, IDENT_VALUE);
            $display("TEST FAILED");
            $finish;
        end

        // ---- read manifest header ----
        fd = $fopen("tb/vectors/jobs.txt", "r");
        if (fd == 0) begin $display("FATAL: cannot open jobs.txt"); $display("TEST FAILED"); $finish; end
        r = $fscanf(fd, "%d %d %d %d %d\n", njobs_f, lanes_f, w_f, aw_f, lw_f);
        if (r != 5) begin $display("FATAL: bad jobs.txt header r=%0d", r); $display("TEST FAILED"); $finish; end
        if (lanes_f!==LANES || w_f!==W || aw_f!==ADDR_WIDTH || lw_f!==LEN_WIDTH) begin
            $display("FATAL: vector geometry (L=%0d W=%0d A=%0d LW=%0d) != DUT (L=%0d W=%0d A=%0d LW=%0d)",
                     lanes_f, w_f, aw_f, lw_f, LANES, W, ADDR_WIDTH, LEN_WIDTH);
            $display("TEST FAILED"); $finish;
        end
        for (j = 0; j < njobs_f; j = j + 1) begin
            r = $fscanf(fd, "%d %d %d %d %d %d\n",
                        idx, src_arr[j], dst_arr[j], len_arr[j], mode_arr[j], pad_arr[j]);
            if (r != 6) begin $display("FATAL: bad job line %0d r=%0d", j, r); $display("TEST FAILED"); $finish; end
        end
        $fclose(fd);

        // ---- run every job ----
        for (j = 0; j < njobs_f; j = j + 1) begin
            // load the source image into device memory at its base address
            if (pad_arr[j] > 0) begin
                fname = $sformatf("tb/vectors/src_%03d.hex", j);
                $readmemh(fname, mem, src_arr[j], src_arr[j] + pad_arr[j] - 1);
            end
            // load the golden output image
            if (len_arr[j] > 0) begin
                fname = $sformatf("tb/vectors/gold_%03d.hex", j);
                $readmemh(fname, gold_mem, 0, len_arr[j] - 1);
            end

            // program the descriptor and launch
            apb_write(REG_SRC,  src_arr[j]);
            apb_write(REG_DST,  dst_arr[j]);
            apb_write(REG_LEN,  len_arr[j]);
            apb_write(REG_MODE, mode_arr[j]);
            apb_write(REG_CTRL, CTRL_START | CTRL_IRQ_EN);

            // wait for completion
            wait_cnt = 0;
            rdv = 0;
            while ((rdv & STATUS_DONE) == 0) begin
                apb_read(REG_STATUS, rdv);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 200000) begin
                    $display("FATAL: job %0d timed out (len=%0d)", j, len_arr[j]);
                    $display("TEST FAILED"); $finish;
                end
            end
            apb_read(REG_CYCLES, cyc);

            // check the destination region against the golden image
            job_mism = 0;
            for (i = 0; i < len_arr[j]; i = i + 1) begin
                if (mem[dst_arr[j] + i] !== gold_mem[i]) begin
                    if (job_mism < 4)
                        $display("  MISMATCH job=%0d i=%0d got=%08x exp=%08x (len=%0d mode=%0d)",
                                 j, i, mem[dst_arr[j] + i], gold_mem[i], len_arr[j], mode_arr[j]);
                    job_mism = job_mism + 1;
                end
            end

            total_mism   = total_mism + job_mism;
            total_checks = total_checks + len_arr[j];
            total_cyc    = total_cyc + cyc;
            total_elems  = total_elems + len_arr[j];
            if (len_arr[j] > peak_len) begin
                peak_len = len_arr[j];
                peak_cyc = cyc;
            end
        end

        // ---- report ----
        $display("----------------------------------------------------------");
        $display("JOBS %0d", njobs_f);
        $display("CHECKS %0d", total_checks);
        $display("MISMATCHES %0d", total_mism);
        $display("HW_CYCLES_TOTAL %0d", total_cyc);
        $display("ELEMS_TOTAL %0d", total_elems);
        $display("PEAK_LEN %0d", peak_len);
        $display("PEAK_CYCLES %0d", peak_cyc);
        $display("LANES %0d", LANES);
        $display("----------------------------------------------------------");
        if (total_mism == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end
endmodule

`default_nettype wire
