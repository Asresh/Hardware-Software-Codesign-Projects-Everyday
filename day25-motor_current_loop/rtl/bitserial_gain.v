// Author: Asresh
`timescale 1ns/1ps
// Eight-cycle shift/add multiplier for signed current error x unsigned Q8 gain.
module bitserial_gain #(
    parameter GAIN_BITS = 8
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start_i,
    input  wire signed [16:0]      error_i,
    input  wire [GAIN_BITS-1:0]    gain_i,
    output reg                     busy_o,
    output reg                     done_o,
    output reg signed [24:0]       product_o
);
reg sign_q;
reg [24:0] multiplicand_q;
reg [GAIN_BITS-1:0] multiplier_q;
reg [24:0] accumulator_q;
reg [3:0] bit_q;
wire [24:0] addend_w = multiplier_q[0] ? multiplicand_q : 25'd0;
wire [24:0] sum_w = accumulator_q + addend_w;
wire [16:0] magnitude_w = error_i[16] ? (~error_i + 17'd1) : error_i;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        busy_o <= 1'b0;
        done_o <= 1'b0;
        product_o <= 25'sd0;
        sign_q <= 1'b0;
        multiplicand_q <= 25'd0;
        multiplier_q <= {GAIN_BITS{1'b0}};
        accumulator_q <= 25'd0;
        bit_q <= 4'd0;
    end else begin
        done_o <= 1'b0;
        if (start_i && !busy_o) begin
            busy_o <= 1'b1;
            sign_q <= error_i[16];
            multiplicand_q <= {{8{1'b0}}, magnitude_w};
            multiplier_q <= gain_i;
            accumulator_q <= 25'd0;
            bit_q <= 4'd0;
        end else if (busy_o) begin
            accumulator_q <= sum_w;
            multiplicand_q <= multiplicand_q << 1;
            multiplier_q <= multiplier_q >> 1;
            if (bit_q == GAIN_BITS-1) begin
                busy_o <= 1'b0;
                done_o <= 1'b1;
                product_o <= sign_q ? -$signed(sum_w) : $signed(sum_w);
            end else begin
                bit_q <= bit_q + 1'b1;
            end
        end
    end
end
endmodule
