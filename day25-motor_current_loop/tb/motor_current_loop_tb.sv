// Author: Asresh
// Pin-level MMIO differential testbench with deterministic host-bus gaps.
`timescale 1ns/1ps
module motor_current_loop_tb;
reg clk = 1'b0;
reg rst_n = 1'b0;
reg bus_valid = 1'b0;
reg bus_write = 1'b0;
reg [5:0] bus_addr = 6'd0;
reg [31:0] bus_wdata = 32'd0;
wire bus_ready;
wire [31:0] bus_rdata;
wire irq;
integer fd, rc, count, i, timeout;
integer ref_i, meas_i, gain_i, trip_i, fault_i, expect_duty, expect_flags, scalar_cost;
integer mismatches = 0;
integer cycle_counter = 0;
integer start_cycle, latency, latency_sum = 0, max_latency = 0;
integer baseline_cycles = 0;
integer gap_seed = 32'h250815;
reg [31:0] read_data;

motor_current_mmio_top dut (
    .clk(clk), .rst_n(rst_n), .bus_valid_i(bus_valid), .bus_write_i(bus_write),
    .bus_addr_i(bus_addr), .bus_wdata_i(bus_wdata), .bus_ready_o(bus_ready),
    .bus_rdata_o(bus_rdata), .irq_o(irq)
);
always #5 clk = ~clk;
always @(posedge clk) if (rst_n) cycle_counter <= cycle_counter + 1;

task automatic bus_gap;
    integer n;
    begin
        n = $random(gap_seed) & 3;
        repeat (n) @(posedge clk);
    end
endtask
task automatic mmio_write(input [5:0] addr, input [31:0] data);
    begin
        bus_gap();
        @(negedge clk); bus_valid = 1'b1; bus_write = 1'b1; bus_addr = addr; bus_wdata = data;
        @(posedge clk); while (!bus_ready) @(posedge clk);
        @(negedge clk); bus_valid = 1'b0; bus_write = 1'b0; bus_addr = 0; bus_wdata = 0;
    end
endtask
task automatic mmio_read(input [5:0] addr, output [31:0] data);
    begin
        bus_gap();
        @(negedge clk); bus_valid = 1'b1; bus_write = 1'b0; bus_addr = addr;
        @(posedge clk); while (!bus_ready) @(posedge clk); data = bus_rdata;
        @(negedge clk); bus_valid = 1'b0; bus_addr = 0;
    end
endtask

initial begin
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    fd = $fopen("vectors.txt", "r");
    if (fd == 0) begin $display("TEST FAILED: cannot open vectors.txt"); $finish(1); end
    rc = $fscanf(fd, "%d\n", count);
    if (rc != 1 || count < 256) begin $display("TEST FAILED: invalid vector count"); $finish(1); end
    mmio_write(6'h00, 32'h3);
    for (i = 0; i < count; i = i + 1) begin
        rc = $fscanf(fd, "%d %d %d %d %d %d %d %d\n", ref_i, meas_i, gain_i,
                    trip_i, fault_i, expect_duty, expect_flags, scalar_cost);
        if (rc != 8) begin $display("TEST FAILED: malformed vector %0d", i); $finish(1); end
        baseline_cycles = baseline_cycles + scalar_cost;
        mmio_write(6'h04, gain_i);
        mmio_write(6'h08, trip_i);
        mmio_write(6'h0c, ref_i);
        mmio_write(6'h10, meas_i);
        mmio_write(6'h14, 1 | (fault_i << 1));
        start_cycle = cycle_counter;
        timeout = 0;
        while (!irq && timeout < 64) begin @(posedge clk); timeout = timeout + 1; end
        latency = cycle_counter - start_cycle;
        latency_sum = latency_sum + latency;
        if (latency > max_latency) max_latency = latency;
        if (!irq) begin $display("mismatch %0d: completion timeout", i); mismatches = mismatches + 1; end
        mmio_read(6'h1c, read_data);
        if (read_data[15:0] !== expect_duty[15:0]) begin
            $display("mismatch %0d: duty got=%0d expected=%0d", i, read_data[15:0], expect_duty);
            mismatches = mismatches + 1;
        end
        mmio_read(6'h18, read_data);
        if (read_data[5:3] !== expect_flags[2:0]) begin
            $display("mismatch %0d: flags got=%0x expected=%0x", i, read_data[5:3], expect_flags);
            mismatches = mismatches + 1;
        end
        mmio_write(6'h24, 1);
        @(posedge clk);
        if (irq) begin $display("mismatch %0d: IRQ did not clear", i); mismatches = mismatches + 1; end
    end
    mmio_read(6'h20, read_data);
    if (read_data != count) begin $display("mismatch: jobs got=%0d expected=%0d", read_data, count); mismatches = mismatches + 1; end
    $display("VECTORS=%0d", count);
    $display("CORE_CYCLES=%0d", latency_sum);
    $display("MEAN_LATENCY=%0.3f", latency_sum * 1.0 / count);
    $display("MAX_LATENCY=%0d", max_latency);
    $display("THROUGHPUT=%0.6f", count * 1.0 / latency_sum);
    $display("BASELINE_CYCLES=%0d", baseline_cycles);
    $display("SPEEDUP=%0.6f", baseline_cycles * 1.0 / latency_sum);
    $display("MISMATCHES=%0d", mismatches);
    if (mismatches == 0) $display("TEST PASSED"); else $display("TEST FAILED");
    $fclose(fd);
    $finish(mismatches != 0);
end
endmodule
