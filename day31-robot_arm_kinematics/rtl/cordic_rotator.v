// Author: Asresh
`timescale 1ns/1ps
module cordic_rotator #(
    parameter ITER = 16
) (
    input wire clk, input wire rst, input wire start,
    input wire signed [17:0] angle_q13,
    output reg busy, output reg done,
    output reg signed [17:0] cos_q15, output reg signed [17:0] sin_q15
);
    localparam signed [17:0] PI = 18'sd25736;
    localparam signed [17:0] HALF_PI = 18'sd12868;
    localparam signed [17:0] K = 18'sd19898;
    reg signed [31:0] x, y;
    reg signed [17:0] z;
    reg [4:0] iter;
    reg signed [17:0] atan_lut [0:15];
    wire signed [31:0] x_shift = y >>> iter;
    wire signed [31:0] y_shift = x >>> iter;
    wire signed [31:0] next_x = z[17] ? (x + x_shift) : (x - x_shift);
    wire signed [31:0] next_y = z[17] ? (y - y_shift) : (y + y_shift);
    wire signed [17:0] next_z = z[17] ? (z + atan_lut[iter]) : (z - atan_lut[iter]);
    initial begin
        atan_lut[0]=18'sd6434; atan_lut[1]=18'sd3798; atan_lut[2]=18'sd2007; atan_lut[3]=18'sd1019;
        atan_lut[4]=18'sd511; atan_lut[5]=18'sd256; atan_lut[6]=18'sd128; atan_lut[7]=18'sd64;
        atan_lut[8]=18'sd32; atan_lut[9]=18'sd16; atan_lut[10]=18'sd8; atan_lut[11]=18'sd4;
        atan_lut[12]=18'sd2; atan_lut[13]=18'sd1; atan_lut[14]=18'sd1; atan_lut[15]=18'sd0;
    end
    always @(posedge clk) begin
        if (rst) begin
            x<=0; y<=0; z<=0; iter<=0; busy<=0; done<=0; cos_q15<=0; sin_q15<=0;
        end else begin
            done <= 0;
            if (start && !busy) begin
                iter <= 0; busy <= 1;
                if (angle_q13 > HALF_PI) begin x <= -K; y <= 0; z <= angle_q13 - PI; end
                else if (angle_q13 < -HALF_PI) begin x <= -K; y <= 0; z <= angle_q13 + PI; end
                else begin x <= K; y <= 0; z <= angle_q13; end
            end else if (busy) begin
                x <= next_x; y <= next_y; z <= next_z;
                if (iter == ITER-1) begin
                    busy <= 0; done <= 1; cos_q15 <= next_x[17:0]; sin_q15 <= next_y[17:0];
                end else iter <= iter + 1'b1;
            end
        end
    end
endmodule
