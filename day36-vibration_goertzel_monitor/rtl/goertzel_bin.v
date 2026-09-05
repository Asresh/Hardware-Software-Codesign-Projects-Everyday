// Author: Asresh
`timescale 1ns/1ps
module goertzel_bin #(
    parameter SAMPLE_W = 12,
    parameter ACC_W = 40,
    parameter COEF_W = 12,
    parameter COEF_FRAC = 8
) (
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         clear,
    input  wire                         accept,
    input  wire                         frame_end,
    input  wire signed [SAMPLE_W-1:0]   sample,
    input  wire signed [COEF_W-1:0]     coefficient,
    output reg  [63:0]                  power,
    output reg                          power_valid
);
    reg signed [ACC_W-1:0] s1;
    reg signed [ACC_W-1:0] s2;
    wire signed [ACC_W+COEF_W-1:0] coef_s1_full = coefficient * s1;
    wire signed [ACC_W-1:0] coef_s1 = coef_s1_full >>> COEF_FRAC;
    wire signed [ACC_W-1:0] sample_ext = {{(ACC_W-SAMPLE_W){sample[SAMPLE_W-1]}}, sample};
    wire signed [ACC_W-1:0] next_s = sample_ext + coef_s1 - s2;
    wire signed [(2*ACC_W)-1:0] next_sq = next_s * next_s;
    wire signed [(2*ACC_W)-1:0] s1_sq = s1 * s1;
    wire signed [(2*ACC_W)+COEF_W-1:0] cross_full = coefficient * next_s * s1;
    wire signed [(2*ACC_W)-1:0] cross_term = cross_full >>> COEF_FRAC;
    wire signed [(2*ACC_W):0] power_wide = next_sq + s1_sq - cross_term;

    always @(posedge clk) begin
        if (rst || clear) begin
            s1 <= {ACC_W{1'b0}};
            s2 <= {ACC_W{1'b0}};
            power <= 64'd0;
            power_valid <= 1'b0;
        end else begin
            power_valid <= 1'b0;
            if (accept) begin
                if (frame_end) begin
                    power <= power_wide[63:0];
                    power_valid <= 1'b1;
                    s1 <= {ACC_W{1'b0}};
                    s2 <= {ACC_W{1'b0}};
                end else begin
                    s2 <= s1;
                    s1 <= next_s;
                end
            end
        end
    end
endmodule
