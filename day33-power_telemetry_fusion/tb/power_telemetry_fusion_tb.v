// Author: Asresh
// Pin-level differential verification. A shared-memory model applies seeded
// read/write stalls, every DMA result is checked against C-generated vectors,
// and protocol corners cover error status plus sticky interrupt acknowledgement.
`timescale 1ns/1ps

module power_telemetry_fusion_tb;
    localparam SAMPLE_COUNT = 320;
    localparam DESC_ADDR = 16'h0100;
    localparam SRC_ADDR = 16'h0200;
    localparam DST_ADDR = 16'h0800;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg mmio_valid = 1'b0;
    reg mmio_write = 1'b0;
    reg [7:0] mmio_addr = 8'd0;
    reg [31:0] mmio_wdata = 32'd0;
    wire mmio_ready;
    wire [31:0] mmio_rdata;
    wire mem_rd_valid;
    wire [15:0] mem_rd_addr;
    reg mem_rd_ready = 1'b0;
    reg [31:0] mem_rd_data;
    wire mem_wr_valid;
    wire [15:0] mem_wr_addr;
    wire [31:0] mem_wr_data;
    reg mem_wr_ready = 1'b0;
    wire irq;

    reg [31:0] memory [0:4095];
    reg [31:0] expected [0:SAMPLE_COUNT-1];
    reg [31:0] lfsr = 32'h5eed_0033;
    integer vector_file;
    integer scan_count;
    integer sample_count;
    integer nominal_mv;
    integer temperature_limit;
    integer droop_weight;
    integer current_weight;
    integer thermal_weight;
    integer alert_threshold;
    reg [63:0] baseline_cycles;
    reg [31:0] sample_word;
    reg [31:0] expected_word;
    integer index;
    integer failures = 0;
    integer elapsed_cycles;
    integer first_read_cycle;
    integer first_write_cycle;
    reg [31:0] measured_busy_cycles;
    reg [31:0] measured_samples;
    reg [31:0] status_value;

    power_telemetry_fusion_top #(
        .ADDR_WIDTH(16), .MAX_SAMPLES(1024)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_valid(mmio_valid), .mmio_write(mmio_write),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
        .mmio_ready(mmio_ready), .mmio_rdata(mmio_rdata),
        .mem_rd_valid(mem_rd_valid), .mem_rd_addr(mem_rd_addr),
        .mem_rd_ready(mem_rd_ready), .mem_rd_data(mem_rd_data),
        .mem_wr_valid(mem_wr_valid), .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data), .mem_wr_ready(mem_wr_ready),
        .irq(irq)
    );

    always #5 clk = ~clk;

    always @* begin
        mem_rd_data = memory[mem_rd_addr[15:2]];
    end

    always @(negedge clk) begin
        if (!rst_n) begin
            mem_rd_ready <= 1'b0;
            mem_wr_ready <= 1'b0;
            lfsr <= 32'h5eed_0033;
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            mem_rd_ready <= lfsr[0] | lfsr[3];
            mem_wr_ready <= lfsr[1] | lfsr[5];
        end
    end

    always @(posedge clk) begin
        if (rst_n && mem_wr_valid && mem_wr_ready)
            memory[mem_wr_addr[15:2]] <= mem_wr_data;
    end

    task mmio_write_word;
        input [7:0] address;
        input [31:0] value;
        begin
            @(negedge clk);
            mmio_valid = 1'b1;
            mmio_write = 1'b1;
            mmio_addr = address;
            mmio_wdata = value;
            @(posedge clk);
            #1;
            @(negedge clk);
            mmio_valid = 1'b0;
            mmio_write = 1'b0;
            mmio_addr = 8'd0;
            mmio_wdata = 32'd0;
        end
    endtask

    task mmio_read_word;
        input [7:0] address;
        output [31:0] value;
        begin
            @(negedge clk);
            mmio_valid = 1'b1;
            mmio_write = 1'b0;
            mmio_addr = address;
            #1 value = mmio_rdata;
            @(posedge clk);
            #1;
            @(negedge clk);
            mmio_valid = 1'b0;
            mmio_addr = 8'd0;
        end
    endtask

    initial begin
        vector_file = $fopen("vectors.txt", "r");
        if (vector_file == 0) begin
            $display("TEST FAILED: cannot open vectors.txt");
            $finish;
        end
        scan_count = $fscanf(vector_file, "%d %d %d %d %d %d %d %d\n",
                            sample_count, nominal_mv, temperature_limit,
                            droop_weight, current_weight, thermal_weight,
                            alert_threshold, baseline_cycles);
        if (scan_count != 8 || sample_count != SAMPLE_COUNT) begin
            $display("TEST FAILED: malformed vector header");
            $finish;
        end
        for (index = 0; index < SAMPLE_COUNT; index = index + 1) begin
            scan_count = $fscanf(vector_file, "%h %h\n", sample_word,
                                expected_word);
            if (scan_count != 2) begin
                $display("TEST FAILED: malformed vector %0d", index);
                $finish;
            end
            memory[(SRC_ADDR >> 2) + index] = sample_word;
            memory[(DST_ADDR >> 2) + index] = 32'hdead_beef;
            expected[index] = expected_word;
        end
        $fclose(vector_file);
        memory[(DESC_ADDR >> 2) + 0] = SRC_ADDR;
        memory[(DESC_ADDR >> 2) + 1] = DST_ADDR;
        memory[(DESC_ADDR >> 2) + 2] = SAMPLE_COUNT;
        memory[(DESC_ADDR >> 2) + 3] = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        mmio_write_word(8'h14, nominal_mv);
        mmio_write_word(8'h18, temperature_limit);
        mmio_write_word(8'h1c, droop_weight | (current_weight << 8) |
                                      (thermal_weight << 16));
        mmio_write_word(8'h20, alert_threshold);
        mmio_write_word(8'h08, DESC_ADDR);
        mmio_write_word(8'h24, 32'd1);
        mmio_write_word(8'h00, 32'd3);

        elapsed_cycles = 0;
        first_read_cycle = -1;
        first_write_cycle = -1;
        while (!irq && elapsed_cycles < 5000) begin
            @(posedge clk);
            elapsed_cycles = elapsed_cycles + 1;
            if (dut.state == 2'd2 && mem_rd_valid && mem_rd_ready &&
                first_read_cycle < 0)
                first_read_cycle = elapsed_cycles;
            if (mem_wr_valid && mem_wr_ready && first_write_cycle < 0)
                first_write_cycle = elapsed_cycles;
        end
        if (!irq) begin
            $display("TEST FAILED: completion timeout");
            $finish;
        end
        mmio_read_word(8'h0c, measured_busy_cycles);
        mmio_read_word(8'h10, measured_samples);
        mmio_read_word(8'h04, status_value);

        if (measured_samples != SAMPLE_COUNT) begin
            $display("sample counter mismatch got=%0d expected=%0d",
                     measured_samples, SAMPLE_COUNT);
            failures = failures + 1;
        end
        if (status_value[2] || status_value[0]) begin
            $display("unexpected final status %08x", status_value);
            failures = failures + 1;
        end
        for (index = 0; index < SAMPLE_COUNT; index = index + 1) begin
            if (memory[(DST_ADDR >> 2) + index] !== expected[index]) begin
                if (failures < 8)
                    $display("mismatch[%0d] got=%08x expected=%08x", index,
                             memory[(DST_ADDR >> 2) + index], expected[index]);
                failures = failures + 1;
            end
        end
        if (first_write_cycle - first_read_cycle != 3) begin
            $display("pipeline latency mismatch got=%0d expected=3",
                     first_write_cycle - first_read_cycle);
            failures = failures + 1;
        end

        mmio_write_word(8'h24, 32'd1);
        if (irq) begin
            $display("interrupt did not clear");
            failures = failures + 1;
        end

        memory[(DESC_ADDR >> 2) + 2] = 0;
        mmio_write_word(8'h00, 32'd3);
        elapsed_cycles = 0;
        while (!irq && elapsed_cycles < 100) begin
            @(posedge clk);
            elapsed_cycles = elapsed_cycles + 1;
        end
        mmio_read_word(8'h04, status_value);
        if (!irq || !status_value[2]) begin
            $display("invalid descriptor did not set error and IRQ: %08x",
                     status_value);
            failures = failures + 1;
        end
        mmio_write_word(8'h24, 32'd1);

        if (failures == 0) begin
            $display("METRIC vectors=%0d", SAMPLE_COUNT);
            $display("METRIC end_to_end_cycles=%0d", measured_busy_cycles + 1);
            $display("METRIC busy_cycles=%0d", measured_busy_cycles);
            $display("METRIC throughput_samples_per_clock=%0f",
                     SAMPLE_COUNT * 1.0 / measured_busy_cycles);
            $display("METRIC pipeline_latency_cycles=%0d",
                     first_write_cycle - first_read_cycle);
            $display("METRIC scalar_baseline_cycles=%0d", baseline_cycles);
            $display("METRIC speedup=%0f",
                     baseline_cycles * 1.0 / (measured_busy_cycles + 1));
            $display("TEST PASSED: 320 vectors plus descriptor/IRQ corners, 0 mismatches");
        end else begin
            $display("TEST FAILED: %0d mismatches", failures);
        end
        $finish;
    end
endmodule
