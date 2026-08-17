// Author: Asresh
// Balanced eight-input reduction tree for the SIMD complex products.
module correlation_reduce #(
    parameter IW = 17,
    parameter OW = IW + 3
) (
    input  signed [(8*IW)-1:0] lane_i,
    input  signed [(8*IW)-1:0] lane_q,
    output signed [OW-1:0] sum_i,
    output signed [OW-1:0] sum_q
);
    wire signed [IW:0] i01 = $signed(lane_i[IW-1:0]) + $signed(lane_i[(2*IW)-1:IW]);
    wire signed [IW:0] i23 = $signed(lane_i[(3*IW)-1:2*IW]) + $signed(lane_i[(4*IW)-1:3*IW]);
    wire signed [IW:0] i45 = $signed(lane_i[(5*IW)-1:4*IW]) + $signed(lane_i[(6*IW)-1:5*IW]);
    wire signed [IW:0] i67 = $signed(lane_i[(7*IW)-1:6*IW]) + $signed(lane_i[(8*IW)-1:7*IW]);
    wire signed [IW:0] q01 = $signed(lane_q[IW-1:0]) + $signed(lane_q[(2*IW)-1:IW]);
    wire signed [IW:0] q23 = $signed(lane_q[(3*IW)-1:2*IW]) + $signed(lane_q[(4*IW)-1:3*IW]);
    wire signed [IW:0] q45 = $signed(lane_q[(5*IW)-1:4*IW]) + $signed(lane_q[(6*IW)-1:5*IW]);
    wire signed [IW:0] q67 = $signed(lane_q[(7*IW)-1:6*IW]) + $signed(lane_q[(8*IW)-1:7*IW]);
    wire signed [IW+1:0] i03 = i01 + i23;
    wire signed [IW+1:0] i47 = i45 + i67;
    wire signed [IW+1:0] q03 = q01 + q23;
    wire signed [IW+1:0] q47 = q45 + q67;

    assign sum_i = i03 + i47;
    assign sum_q = q03 + q47;
endmodule
