// ============================================================================
// arc_reduce_pe.v - one reduction processing element.
//
// Combinational element-wise reduction of two operands under a 2-bit op code:
//   SUM  (0): wrapping DW-bit add
//   PROD (1): wrapping DW-bit multiply
//   MAX  (2): signed maximum
//   MIN  (3): signed minimum
//
// The systolic array registers the PE outputs; the PE itself is pure combi-
// national logic so a whole reduction stage settles in one clock.  Every op
// is exact two's-complement arithmetic, so hardware == C golden bit-for-bit.
// ============================================================================
`default_nettype none

module arc_reduce_pe #(
    parameter integer DW = 32
) (
    input  wire [1:0]     op,
    input  wire [DW-1:0]  a,      // running partial (from previous stage)
    input  wire [DW-1:0]  b,      // this rank's operand
    output reg  [DW-1:0]  y
);
    localparam [1:0] OP_SUM = 2'd0, OP_PROD = 2'd1, OP_MAX = 2'd2, OP_MIN = 2'd3;

    always @* begin
        case (op)
            OP_SUM:  y = a + b;                                   // wraps at DW
            OP_PROD: y = a * b;                                   // wraps at DW
            OP_MAX:  y = ($signed(a) > $signed(b)) ? a : b;
            OP_MIN:  y = ($signed(a) < $signed(b)) ? a : b;
            default: y = a;
        endcase
    end
endmodule

`default_nettype wire
