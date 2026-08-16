// Author: Asresh
`timescale 1ns/1ps
// Top-level mailbox-controlled motor phase-current accelerator.
module motor_current_mmio_top #(
    parameter FIFO_DEPTH = 4
) (
    input  wire clk,
    input  wire rst_n,
    input  wire bus_valid_i,
    input  wire bus_write_i,
    input  wire [5:0] bus_addr_i,
    input  wire [31:0] bus_wdata_i,
    output wire bus_ready_o,
    output wire [31:0] bus_rdata_o,
    output wire irq_o
);
wire cmd_valid_w, cmd_ready_w, core_busy_w;
wire signed [15:0] ref_w, meas_w;
wire [7:0] gain_w;
wire [15:0] trip_w;
wire fault_w;
wire result_valid_w, result_ready_w;
wire [15:0] result_duty_w;
wire [2:0] result_flags_w;

motor_mailbox_regs u_regs (
    .clk(clk), .rst_n(rst_n), .bus_valid_i(bus_valid_i), .bus_write_i(bus_write_i),
    .bus_addr_i(bus_addr_i), .bus_wdata_i(bus_wdata_i), .bus_ready_o(bus_ready_o),
    .bus_rdata_o(bus_rdata_o), .cmd_valid_o(cmd_valid_w), .cmd_ready_i(cmd_ready_w),
    .ref_o(ref_w), .meas_o(meas_w), .gain_o(gain_w), .trip_o(trip_w), .fault_o(fault_w),
    .core_busy_i(core_busy_w), .result_valid_i(result_valid_w), .result_ready_o(result_ready_w),
    .result_duty_i(result_duty_w), .result_flags_i(result_flags_w), .irq_o(irq_o)
);
motor_current_core #(.FIFO_DEPTH(FIFO_DEPTH)) u_core (
    .clk(clk), .rst_n(rst_n), .cmd_valid_i(cmd_valid_w), .cmd_ready_o(cmd_ready_w),
    .ref_i(ref_w), .meas_i(meas_w), .gain_i(gain_w), .trip_i(trip_w), .fault_i(fault_w),
    .result_valid_o(result_valid_w), .result_ready_i(result_ready_w),
    .duty_o(result_duty_w), .flags_o(result_flags_w), .busy_o(core_busy_w)
);
endmodule
