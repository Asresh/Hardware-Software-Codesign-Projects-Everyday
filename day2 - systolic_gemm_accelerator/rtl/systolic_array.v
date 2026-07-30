// -----------------------------------------------------------------------------
// systolic_array.v
// An N x N grid of output-stationary processing elements. Operand A enters the
// left edge (one lane per row) and marches rightward; operand B enters the top
// edge (one lane per column) and marches downward. After the feeder has pushed
// a K-long, diagonally-skewed wavefront through the grid, PE[i][j] holds
//
//     C[i][j] = sum_{k=0..K-1} A[i][k] * B[k][j]
//
// and the whole tile is read straight out of the accumulators (no drain pass is
// needed because the product is output-stationary).
//
// Wiring convention for the flattened ports: index = i*N + j, row-major, with
// i the row (A direction) and j the column (B direction). a_left/b_top are the
// N edge inputs; acc_flat exposes all N*N accumulators.
// -----------------------------------------------------------------------------
`default_nettype none

module systolic_array #(
    parameter integer N          = 8,
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 32
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          en,      // advance every PE one step
    input  wire                          clr,     // zero every accumulator

    input  wire [N*DATA_WIDTH-1:0]       a_left,  // A edge, one lane per row i
    input  wire [N*DATA_WIDTH-1:0]       b_top,   // B edge, one lane per column j

    output wire [N*N*ACC_WIDTH-1:0]      acc_flat // C[i][j] at index (i*N+j)
);
    // Horizontal (A) and vertical (B) interconnect. h[i][j] is the A value
    // entering PE[i][j] from its left; v[i][j] is the B value entering from
    // above. Column 0 / row 0 are driven by the edge inputs.
    wire signed [DATA_WIDTH-1:0] h [0:N-1][0:N];   // h[i][0]=edge, h[i][N]=spill
    wire signed [DATA_WIDTH-1:0] v [0:N][0:N-1];   // v[0][j]=edge, v[N][j]=spill

    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_row_edge
            assign h[i][0] = a_left[i*DATA_WIDTH +: DATA_WIDTH];
        end
        for (j = 0; j < N; j = j + 1) begin : g_col_edge
            assign v[0][j] = b_top[j*DATA_WIDTH +: DATA_WIDTH];
        end

        for (i = 0; i < N; i = i + 1) begin : g_pe_row
            for (j = 0; j < N; j = j + 1) begin : g_pe_col
                pe #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) u_pe (
                    .clk(clk), .rst_n(rst_n), .en(en), .clr(clr),
                    .a_in (h[i][j]),
                    .b_in (v[i][j]),
                    .a_out(h[i][j+1]),
                    .b_out(v[i+1][j]),
                    .acc  (acc_flat[(i*N+j)*ACC_WIDTH +: ACC_WIDTH])
                );
            end
        end
    endgenerate
endmodule

`default_nettype wire
