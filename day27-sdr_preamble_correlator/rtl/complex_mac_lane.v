// Author: Asresh
// One signed complex multiply by a conjugated reference sample.
module complex_mac_lane #(
    parameter W = 8
) (
    input  signed [W-1:0] sample_i,
    input  signed [W-1:0] sample_q,
    input  signed [W-1:0] tap_i,
    input  signed [W-1:0] tap_q,
    output signed [(2*W):0] product_i,
    output signed [(2*W):0] product_q
);
    wire signed [(2*W)-1:0] ii = sample_i * tap_i;
    wire signed [(2*W)-1:0] qq = sample_q * tap_q;
    wire signed [(2*W)-1:0] qi = sample_q * tap_i;
    wire signed [(2*W)-1:0] iq = sample_i * tap_q;

    assign product_i = $signed(ii) + $signed(qq);
    assign product_q = $signed(qi) - $signed(iq);
endmodule
