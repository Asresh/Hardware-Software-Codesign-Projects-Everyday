// ============================================================================
// ann_distance_pe.v - one SIMD distance lane.
//
// Computes a single dimension's contribution to the vector score, exactly as
// the reference model does, for both supported metrics:
//   metric==0 (L2): (q - x)^2   -- always >= 0, kept as a positive value
//   metric==1 (IP): q * x       -- signed inner-product term
// The result is sign-correct in a 32-bit signed domain so the adder tree above
// can accumulate lanes and chunks without any per-metric special casing.
// ============================================================================
`default_nettype none

module ann_distance_pe #(parameter integer DW = 8) (
    input  wire signed [DW-1:0] q,
    input  wire signed [DW-1:0] x,
    input  wire                 metric,     // 0 = L2, 1 = IP
    output wire signed [31:0]   y
);
    wire signed [DW:0]     diff = q - x;          // [-255,255] for DW=8
    wire signed [2*DW+1:0] sq   = diff * diff;     // >= 0, <= 65025
    wire signed [2*DW-1:0] pr   = q * x;           // signed product

    // L2: zero-extend the non-negative square; IP: sign-extend the product.
    assign y = metric ? {{(32-2*DW){pr[2*DW-1]}}, pr}
                      : {{(32-(2*DW+2)){1'b0}}, sq};
endmodule

`default_nettype wire
