// -----------------------------------------------------------------------------
// pe.v
// One processing element of the output-stationary systolic array. Every PE
// owns a single output accumulator C[i][j] and forwards its two operands to its
// neighbours so that a whole matrix product streams through the grid.
//
//   * A values flow left -> right : a_out is a_in delayed one cycle.
//   * B values flow top  -> bottom: b_out is b_in delayed one cycle.
//   * Each enabled cycle the PE performs one signed multiply-accumulate,
//         acc <= acc + a_in * b_in
//     using the *combinational* inputs (the same values it is about to
//     register for its neighbours), so the operand that is multiplied here is
//     the one that is handed on next cycle. This one-cycle-per-hop delay is
//     exactly what aligns A[i][k] and B[k][j] at PE[i][j] on the same cycle
//     when the array edges are fed with a diagonal skew (see gemm_feeder.v).
//
// `clr` synchronously zeroes the accumulator at the start of a fresh tile;
// leaving it low lets a new K-run accumulate onto the previous result, which is
// how software accumulates a product over a K dimension larger than one tile.
// The accumulator is ACC_WIDTH bits so the full-precision sum of KMAX signed
// DATA_WIDTH*DATA_WIDTH products never overflows, keeping the array bit-exact
// against a wide-integer software model.
// -----------------------------------------------------------------------------
`default_nettype none

module pe #(
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 32
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          en,      // advance one systolic step
    input  wire                          clr,     // zero the accumulator (tile start)

    input  wire signed [DATA_WIDTH-1:0]  a_in,    // from left neighbour / edge
    input  wire signed [DATA_WIDTH-1:0]  b_in,    // from top neighbour  / edge

    output reg  signed [DATA_WIDTH-1:0]  a_out,   // to right neighbour
    output reg  signed [DATA_WIDTH-1:0]  b_out,   // to bottom neighbour
    output wire signed [ACC_WIDTH-1:0]   acc      // this PE's output element
);
    localparam integer PROD_WIDTH = 2 * DATA_WIDTH;

    reg  signed [ACC_WIDTH-1:0]  acc_q;

    // Signed product of the two combinational inputs, sign-extended to ACC_WIDTH.
    wire signed [PROD_WIDTH-1:0] prod     = a_in * b_in;
    wire signed [ACC_WIDTH-1:0]  prod_ext =
        {{(ACC_WIDTH-PROD_WIDTH){prod[PROD_WIDTH-1]}}, prod};

    always @(posedge clk) begin
        if (!rst_n) begin
            acc_q <= {ACC_WIDTH{1'b0}};
            a_out <= {DATA_WIDTH{1'b0}};
            b_out <= {DATA_WIDTH{1'b0}};
        end else begin
            if (clr)      acc_q <= {ACC_WIDTH{1'b0}};
            else if (en)  acc_q <= acc_q + prod_ext;

            if (en) begin
                a_out <= a_in;
                b_out <= b_in;
            end
        end
    end

    assign acc = acc_q;
endmodule

`default_nettype wire
