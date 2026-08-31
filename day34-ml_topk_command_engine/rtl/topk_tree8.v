// Author: Asresh
// Balanced 8-to-2 signed reduction tree: four leaf pairs, two intermediate
// merges, and one root merge. Results register one cycle after start.
`timescale 1ns/1ps
module topk_tree8 (
    input wire clk, input wire rst_n, input wire start,
    input wire [127:0] scores,
    output reg valid, output reg signed [15:0] top0_value,
    output reg [2:0] top0_index, output reg signed [15:0] top1_value,
    output reg [2:0] top1_index
);
    wire signed [15:0] p0v [0:3]; wire [2:0] p0i [0:3];
    wire signed [15:0] p1v [0:3]; wire [2:0] p1i [0:3];
    wire signed [15:0] m0v [0:1]; wire [2:0] m0i [0:1];
    wire signed [15:0] m1v [0:1]; wire [2:0] m1i [0:1];
    wire signed [15:0] rv0, rv1; wire [2:0] ri0, ri1;
    genvar g;
    generate for (g=0; g<4; g=g+1) begin: LEAF
        localparam [2:0] A_INDEX = 2*g;
        localparam [2:0] B_INDEX = 2*g+1;
        topk_pair pair(.a_value(scores[(2*g)*16 +: 16]), .a_index(A_INDEX),
            .b_value(scores[(2*g+1)*16 +: 16]), .b_index(B_INDEX),
            .first_value(p0v[g]), .first_index(p0i[g]),
            .second_value(p1v[g]), .second_index(p1i[g]));
    end endgenerate
    topk_merge merge0(.a0v(p0v[0]),.a0i(p0i[0]),.a1v(p1v[0]),.a1i(p1i[0]),
        .b0v(p0v[1]),.b0i(p0i[1]),.b1v(p1v[1]),.b1i(p1i[1]),
        .o0v(m0v[0]),.o0i(m0i[0]),.o1v(m1v[0]),.o1i(m1i[0]));
    topk_merge merge1(.a0v(p0v[2]),.a0i(p0i[2]),.a1v(p1v[2]),.a1i(p1i[2]),
        .b0v(p0v[3]),.b0i(p0i[3]),.b1v(p1v[3]),.b1i(p1i[3]),
        .o0v(m0v[1]),.o0i(m0i[1]),.o1v(m1v[1]),.o1i(m1i[1]));
    topk_merge root(.a0v(m0v[0]),.a0i(m0i[0]),.a1v(m1v[0]),.a1i(m1i[0]),
        .b0v(m0v[1]),.b0i(m0i[1]),.b1v(m1v[1]),.b1i(m1i[1]),
        .o0v(rv0),.o0i(ri0),.o1v(rv1),.o1i(ri1));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin valid<=0; top0_value<=0; top0_index<=0; top1_value<=0; top1_index<=0; end
        else begin
            valid <= start;
            if (start) begin top0_value<=rv0; top0_index<=ri0; top1_value<=rv1; top1_index<=ri1; end
        end
    end
endmodule
