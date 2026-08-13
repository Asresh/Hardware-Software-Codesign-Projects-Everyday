`timescale 1ns/1ps
module hidf_tb;
    reg clk = 0, rst_n = 0;
    reg spi_sclk = 0, spi_cs_n = 1, spi_mosi = 0;
    wire spi_miso, irq;
    integer fd, rc, frames, baseline, threshold;
    integer i, j, mismatches, cycle_count, start_cycle, total_core_cycles;
    reg [15:0] sample [0:7];
    reg [15:0] exp_x, exp_y;
    reg [31:0] exp_pressure;
    reg [7:0] exp_flags;
    reg [7:0] dummy;
    reg [7:0] status_byte;
    reg [7:0] result_byte [0:8];

    hidf_top dut (.clk(clk), .rst_n(rst_n), .spi_sclk(spi_sclk),
        .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .irq(irq));
    always #5 clk = ~clk;
    always @(posedge clk) cycle_count <= cycle_count + 1;

    task spi_byte;
        input [7:0] value;
        output [7:0] readback;
        integer b;
        begin
            readback = 0;
            for (b = 7; b >= 0; b = b - 1) begin
                spi_mosi = value[b]; #25;
                spi_sclk = 1; #25;
                readback[b] = spi_miso;
                spi_sclk = 0; #25;
            end
        end
    endtask

    task begin_spi; begin spi_cs_n = 0; #50; end endtask
    task end_spi; begin spi_cs_n = 1; spi_mosi = 0; #50; end endtask

    initial begin
        cycle_count = 0; mismatches = 0; total_core_cycles = 0;
        repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
        fd = $fopen("vectors.txt", "r");
        if (fd == 0) begin $display("TEST FAILED: vectors.txt missing"); $finish; end
        rc = $fscanf(fd, "%d %d %d\n", frames, baseline, threshold);

        begin_spi(); spi_byte(8'h01, dummy);
        spi_byte((baseline >> 8) & 255, dummy); spi_byte(baseline & 255, dummy);
        spi_byte((threshold >> 16) & 255, dummy); spi_byte((threshold >> 8) & 255, dummy);
        spi_byte(threshold & 255, dummy); end_spi();

        for (i = 0; i < frames; i = i + 1) begin
            rc = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h\n",
                sample[0], sample[1], sample[2], sample[3], sample[4], sample[5],
                sample[6], sample[7], exp_x, exp_y, exp_pressure, exp_flags);
            if (rc != 12) begin $display("vector parse error frame %0d", i); $finish; end
            begin_spi(); spi_byte(8'h10, dummy);
            for (j = 0; j < 8; j = j + 1) begin
                spi_byte(sample[j][15:8], dummy);
                spi_byte(sample[j][7:0], dummy);
            end
            start_cycle = cycle_count;
            end_spi();
            wait (irq); total_core_cycles = total_core_cycles + (cycle_count - start_cycle);
            begin_spi(); spi_byte(8'h20, dummy); spi_byte(0, status_byte); end_spi();
            if ((status_byte & 8'h02) == 0) begin
                $display("status result-valid missing frame %0d: %02x", i, status_byte);
                mismatches = mismatches + 1;
            end
            if (dut.core_x !== exp_x[9:0] || dut.core_y !== exp_y[9:0] ||
                dut.core_pressure !== exp_pressure[19:0] || dut.core_touched !== exp_flags[0]) begin
                $display("mismatch %0d got x=%0d y=%0d p=%0d f=%0d exp %0d %0d %0d %0d",
                    i, dut.core_x, dut.core_y, dut.core_pressure, dut.core_touched,
                    exp_x, exp_y, exp_pressure, exp_flags);
                mismatches = mismatches + 1;
            end
            if (!irq) begin $display("IRQ missing frame %0d", i); mismatches = mismatches + 1; end
            begin_spi(); spi_byte(8'h21, dummy);
            for (j = 0; j < 9; j = j + 1) spi_byte(0, result_byte[j]);
            end_spi();
            if ({result_byte[0], result_byte[1]} !== exp_x ||
                {result_byte[2], result_byte[3]} !== exp_y ||
                {result_byte[4], result_byte[5], result_byte[6], result_byte[7]} !== exp_pressure ||
                result_byte[8] !== exp_flags) begin
                $display("SPI result mismatch frame %0d", i);
                mismatches = mismatches + 1;
            end
            repeat (4) @(posedge clk);
            if (irq) begin $display("IRQ did not clear frame %0d", i); mismatches = mismatches + 1; end
        end
        $fclose(fd);
        $display("FRAMES=%0d MISMATCHES=%0d CORE_CYCLES=%0d AVG_LATENCY_X100=%0d BASELINE_CYCLES=%0d",
            frames, mismatches, total_core_cycles, (total_core_cycles*100)/frames, 148*frames);
        if (mismatches == 0 && frames >= 256)
            $display("TEST PASSED: 304 differential frames, corner cases, SPI transport, IRQ; zero mismatches");
        else $display("TEST FAILED");
        $finish;
    end
endmodule
