// Author: Asresh
`timescale 1ns/1ps
// Converts signed Q8 correction to center-aligned unsigned PWM command.
module pwm_clamp (
    input  wire signed [24:0] product_i,
    input  wire fault_i,
    output reg  [15:0] duty_o,
    output reg         sat_hi_o,
    output reg         sat_lo_o
);
wire signed [25:0] scaled_w = $signed(product_i) >>> 8;
wire signed [25:0] command_w = scaled_w + 26'sd32768;
always @* begin
    duty_o = 16'd0;
    sat_hi_o = 1'b0;
    sat_lo_o = 1'b0;
    if (fault_i) begin
        duty_o = 16'd0;
    end else if (command_w > 26'sd65535) begin
        duty_o = 16'hffff;
        sat_hi_o = 1'b1;
    end else if (command_w < 0) begin
        duty_o = 16'd0;
        sat_lo_o = 1'b1;
    end else begin
        duty_o = command_w[15:0];
    end
end
endmodule
