// Author: Asresh
`timescale 1ns/1ps
// FIFO -> error/guard -> bit-serial gain -> PWM clamp datapath.
module motor_current_core #(
    parameter FIFO_DEPTH = 4
) (
    input  wire clk,
    input  wire rst_n,
    input  wire cmd_valid_i,
    output wire cmd_ready_o,
    input  wire signed [15:0] ref_i,
    input  wire signed [15:0] meas_i,
    input  wire [7:0] gain_i,
    input  wire [15:0] trip_i,
    input  wire fault_i,
    output reg  result_valid_o,
    input  wire result_ready_i,
    output reg  [15:0] duty_o,
    output reg  [2:0] flags_o,
    output wire busy_o
);
wire fifo_valid_w, fifo_pop_w;
wire signed [15:0] fifo_ref_w, fifo_meas_w;
wire [7:0] fifo_gain_w;
wire [15:0] fifo_trip_w;
wire fifo_fault_w;
reg signed [15:0] active_meas_q;
reg signed [15:0] active_ref_q;
reg [15:0] active_trip_q;
reg active_fault_q;
reg [7:0] active_gain_q;
wire signed [16:0] error_w;
wire guard_trip_w;
reg mul_start_q;
wire mul_busy_w, mul_done_w;
wire signed [24:0] product_w;
wire [15:0] clamp_duty_w;
wire clamp_hi_w, clamp_lo_w;

command_fifo #(.DEPTH(FIFO_DEPTH)) u_fifo (
    .clk(clk), .rst_n(rst_n), .push_i(cmd_valid_i), .ready_o(cmd_ready_o),
    .ref_i(ref_i), .meas_i(meas_i), .gain_i(gain_i), .trip_i(trip_i), .fault_i(fault_i), .pop_i(fifo_pop_w),
    .valid_o(fifo_valid_w), .ref_o(fifo_ref_w), .meas_o(fifo_meas_w), .gain_o(fifo_gain_w),
    .trip_o(fifo_trip_w), .fault_o(fifo_fault_w)
);
phase_error u_error (.reference_i(active_ref_q), .measured_i(active_meas_q), .error_o(error_w));
overcurrent_guard u_guard (.measured_i(active_meas_q), .trip_i(active_trip_q), .fault_i(active_fault_q), .trip_o(guard_trip_w));
bitserial_gain u_gain (.clk(clk), .rst_n(rst_n), .start_i(mul_start_q), .error_i(error_w),
    .gain_i(active_gain_q), .busy_o(mul_busy_w), .done_o(mul_done_w), .product_o(product_w));
pwm_clamp u_clamp (.product_i(product_w), .fault_i(guard_trip_w), .duty_o(clamp_duty_w),
    .sat_hi_o(clamp_hi_w), .sat_lo_o(clamp_lo_w));

assign fifo_pop_w = fifo_valid_w && !mul_busy_w && !mul_start_q && !result_valid_o;
assign busy_o = fifo_valid_w || mul_busy_w || mul_start_q || result_valid_o;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mul_start_q <= 1'b0;
        result_valid_o <= 1'b0;
        duty_o <= 16'd0;
        flags_o <= 3'd0;
        active_meas_q <= 16'sd0;
        active_ref_q <= 16'sd0;
        active_trip_q <= 16'd0;
        active_fault_q <= 1'b0;
        active_gain_q <= 8'd0;
    end else begin
        mul_start_q <= 1'b0;
        if (fifo_pop_w) begin
            active_ref_q <= fifo_ref_w;
            active_meas_q <= fifo_meas_w;
            active_trip_q <= fifo_trip_w;
            active_fault_q <= fifo_fault_w;
            active_gain_q <= fifo_gain_w;
            mul_start_q <= 1'b1;
        end
        if (mul_done_w) begin
            duty_o <= clamp_duty_w;
            flags_o <= {clamp_lo_w, clamp_hi_w, guard_trip_w};
            result_valid_o <= 1'b1;
        end
        if (result_valid_o && result_ready_i)
            result_valid_o <= 1'b0;
    end
end
endmodule
