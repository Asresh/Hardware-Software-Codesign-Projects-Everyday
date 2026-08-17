// Author: Asresh
// Converts the signed complex correlation to unsigned magnitude squared.
module magnitude_square #(
    parameter W = 20
) (
    input  signed [W-1:0] value_i,
    input  signed [W-1:0] value_q,
    output [(2*W):0] magnitude
);
    wire [(2*W)-1:0] i2 = value_i * value_i;
    wire [(2*W)-1:0] q2 = value_q * value_q;
    assign magnitude = {1'b0, i2} + {1'b0, q2};
endmodule
