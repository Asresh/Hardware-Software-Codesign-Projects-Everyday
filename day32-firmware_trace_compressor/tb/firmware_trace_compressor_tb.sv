// Author: Asresh
`timescale 1ns/1ps
module firmware_trace_compressor_tb;
    localparam MAX_RECORDS = 512;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg bus_valid = 1'b0;
    reg bus_write = 1'b0;
    reg [12:0] bus_addr = 13'b0;
    reg [31:0] bus_wdata = 32'b0;
    wire bus_ready;
    wire [31:0] bus_rdata;
    wire irq;
    reg [31:0] inputs [0:MAX_RECORDS-1];
    reg [63:0] expected [0:MAX_RECORDS-1];
    integer record_count, packet_count, baseline_cycles;
    integer fd, rc, i, mismatches, clocks, start_clock, irq_clock;
    integer engine_cycles, observed_packets;
    reg [31:0] read_value, lo, hi;
    reg [63:0] observed;
    reg [1023:0] header;
    real throughput, speedup;

    always #5 clk = ~clk;
    always @(posedge clk) clocks <= clocks + 1;

    firmware_trace_compressor_top dut (
        .clk(clk), .rst_n(rst_n), .bus_valid(bus_valid), .bus_write(bus_write),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_ready(bus_ready),
        .bus_rdata(bus_rdata), .irq(irq));

    task mmio_write;
        input [12:0] addr;
        input [31:0] data;
        begin
            @(negedge clk); bus_valid = 1'b1; bus_write = 1'b1;
            bus_addr = addr; bus_wdata = data;
            @(posedge clk);
            if (!bus_ready) begin $display("TEST FAILED bus write timeout"); $finish; end
            @(negedge clk); bus_valid = 1'b0; bus_write = 1'b0;
        end
    endtask

    task mmio_read;
        input [12:0] addr;
        output [31:0] data;
        begin
            @(negedge clk); bus_valid = 1'b1; bus_write = 1'b0; bus_addr = addr;
            @(posedge clk);
            if (!bus_ready) begin $display("TEST FAILED bus read timeout"); $finish; end
            data = bus_rdata;
            @(negedge clk); bus_valid = 1'b0;
        end
    endtask

    initial begin
        clocks = 0;
        mismatches = 0;
        fd = $fopen("vectors.txt", "r");
        if (fd == 0) begin $display("TEST FAILED cannot open vectors.txt"); $finish; end
        rc = $fgets(header, fd);
        rc = $fscanf(fd, "META %d %d %d\n", record_count, packet_count, baseline_cycles);
        if (rc != 3 || record_count < 320 || record_count > MAX_RECORDS) begin
            $display("TEST FAILED invalid metadata"); $finish;
        end
        for (i = 0; i < record_count; i = i + 1) begin
            rc = $fscanf(fd, "IN %h\n", inputs[i]);
            if (rc != 1) begin $display("TEST FAILED malformed input %0d", i); $finish; end
        end
        for (i = 0; i < packet_count; i = i + 1) begin
            rc = $fscanf(fd, "OUT %h\n", expected[i]);
            if (rc != 1) begin $display("TEST FAILED malformed output %0d", i); $finish; end
        end
        $fclose(fd);

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        for (i = 0; i < record_count; i = i + 1)
            mmio_write(13'h0100 + i * 4, inputs[i]);
        mmio_write(13'h0008, record_count);
        start_clock = clocks;
        mmio_write(13'h0000, 32'h00000003);
        i = 0;
        while (!irq && i < 5000) begin @(posedge clk); i = i + 1; end
        irq_clock = clocks;
        if (!irq) begin $display("TEST FAILED interrupt timeout"); $finish; end
        mmio_read(13'h000c, read_value);
        observed_packets = read_value;
        mmio_read(13'h0010, read_value);
        engine_cycles = read_value;
        if (observed_packets != packet_count) begin
            $display("packet count mismatch got=%0d expected=%0d", observed_packets, packet_count);
            mismatches = mismatches + 1;
        end
        for (i = 0; i < observed_packets; i = i + 1) begin
            mmio_read(13'h1000 + i * 8, lo);
            mmio_read(13'h1004 + i * 8, hi);
            observed = {hi, lo};
            if (observed !== expected[i]) begin
                if (mismatches < 8)
                    $display("mismatch[%0d] got=%016h expected=%016h", i, observed, expected[i]);
                mismatches = mismatches + 1;
            end
        end
        if (!irq) begin $display("TEST FAILED IRQ was not sticky"); $finish; end
        mmio_write(13'h0000, 32'h00000006);
        if (irq) begin $display("TEST FAILED IRQ clear failed"); $finish; end

        mmio_write(13'h0008, 32'd0);
        mmio_write(13'h0000, 32'h00000003);
        if (!irq) begin $display("TEST FAILED invalid-count IRQ missing"); $finish; end
        mmio_read(13'h0004, read_value);
        if ((read_value & 32'hc) != 32'hc) begin
            $display("TEST FAILED invalid-count status=%08h", read_value); $finish;
        end
        mmio_write(13'h0000, 32'h00000006);

        throughput = record_count;
        throughput = throughput / engine_cycles;
        speedup = baseline_cycles;
        speedup = speedup / (irq_clock - start_clock);
        if (mismatches != 0) begin
            $display("TEST FAILED mismatches=%0d", mismatches);
            $finish;
        end
        $display("TEST PASSED records=%0d packets=%0d mismatches=0 total_cycles=%0d engine_cycles=%0d latency=%0d throughput=%0.6f baseline_cycles=%0d speedup=%0.6f",
                 record_count, packet_count, irq_clock - start_clock,
                 engine_cycles, irq_clock - start_clock, throughput,
                 baseline_cycles, speedup);
        $finish;
    end
endmodule
