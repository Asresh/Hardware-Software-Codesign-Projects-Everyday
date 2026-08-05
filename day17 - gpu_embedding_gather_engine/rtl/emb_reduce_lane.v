// ============================================================================
// emb_reduce_lane - one SIMD lane of the pooling reduction.
//
// Folds one staged element into the running accumulator for that element
// position.  `first` is asserted for the first row that is actually pooled on
// this device, which initialises the accumulator instead of combining into it -
// that is what makes MAX/MIN correct without needing a sentinel, and it means an
// all-remote bag never touches the accumulator at all.
//
// SUM and MEAN share the adder: MEAN is a plain wrapping 32-bit sum here and the
// divide-by-count happens once per element at drain time, not once per row.
// ============================================================================
`include "emb_defs.vh"

module emb_reduce_lane (
    input  wire [1:0]         op,
    input  wire               first,
    input  wire signed [31:0] acc,
    input  wire signed [31:0] val,
    output reg  signed [31:0] res
);
    always @* begin
        if (first) begin
            res = val;
        end else begin
            case (op)
            `EMB_OP_SUM,
            `EMB_OP_MEAN: res = acc + val;               // two's-complement wrap
            `EMB_OP_MAX:  res = (val > acc) ? val : acc;  // signed compare
            default:      res = (val < acc) ? val : acc;
            endcase
        end
    end
endmodule
