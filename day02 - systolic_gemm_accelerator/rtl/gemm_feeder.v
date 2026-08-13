// -----------------------------------------------------------------------------
// gemm_feeder.v
// Sequencer + input-alignment engine for the systolic array. On START it walks
// a cycle counter t = 0..TC-1 and, each step, presents wavefront k = t of the
// operands: column k of A (one byte per row) and row k of B (one byte per
// column), taking zeros once t reaches K.
//
// The array needs A[i][k] and B[k][j] to arrive at PE[i][j] on the same cycle.
// Because each PE hop costs one cycle, that is achieved by a *diagonal skew*:
// the lane feeding row i of A is delayed by i cycles and the lane feeding
// column j of B is delayed by j cycles. Those delays are the triangular shift
// registers a_sr / b_sr below (lane m is tapped at stage m-1, so lane 0 is a
// straight pass-through). This is the classic systolic input-skew network.
//
// Run length TC = K + 2*N covers the last useful MAC at PE[N-1][N-1], which
// happens at t = K-1 + 2*(N-1); the two trailing cycles feed only zeros, so
// they add nothing to the accumulators and keep the schedule robust.
//
//   SETUP : one cycle, clears the accumulators (unless accumulate mode) and
//           the skew registers, latches K and the accumulate flag.
//   RUN   : TC cycles, en high, wavefronts streamed through the skew network.
//   DONE  : one-cycle done pulse back to the top-level completion logic.
// -----------------------------------------------------------------------------
`default_nettype none

module gemm_feeder #(
    parameter integer N          = 8,
    parameter integer DATA_WIDTH = 8,
    parameter integer KMAX       = 64,
    parameter integer KW         = $clog2(KMAX + 1)
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    start,       // one-cycle launch pulse
    input  wire [KW-1:0]           klen,        // inner dimension, 1..KMAX
    input  wire                    accum_mode,  // 1 = add onto existing C

    // buffer read port: request wavefront rd_k, receive its A column / B row
    output wire [KW-1:0]           rd_k,
    input  wire [N*DATA_WIDTH-1:0] a_col,       // { A[N-1][rd_k]..A[0][rd_k] }
    input  wire [N*DATA_WIDTH-1:0] b_row,       // { B[rd_k][N-1]..B[rd_k][0] }

    // array control / edges
    output wire                    en,
    output wire                    clr,
    output wire [N*DATA_WIDTH-1:0] a_left,      // A edge, one lane per row
    output wire [N*DATA_WIDTH-1:0] b_top,       // B edge, one lane per column

    output wire                    busy,
    output reg                     done_pulse
);
    localparam [1:0] S_IDLE = 2'd0, S_SETUP = 2'd1, S_RUN = 2'd2, S_DONE = 2'd3;

    reg [1:0]  state;
    reg [15:0] t;
    reg [15:0] tc_q;
    reg [KW-1:0] klen_q;
    reg        accum_q;

    // ---- triangular skew shift registers (lane m tapped at stage m-1) ----
    reg [DATA_WIDTH-1:0] a_sr [0:N-1][0:N-1];
    reg [DATA_WIDTH-1:0] b_sr [0:N-1][0:N-1];

    wire feed_valid = (state == S_RUN) && (t < {{(16-KW){1'b0}}, klen_q});
    assign rd_k = feed_valid ? t[KW-1:0] : {KW{1'b0}};

    // Per-lane feed value (masked to zero outside the K wavefronts).
    wire [DATA_WIDTH-1:0] a_feed [0:N-1];
    wire [DATA_WIDTH-1:0] b_feed [0:N-1];
    genvar m;
    generate
        for (m = 0; m < N; m = m + 1) begin : g_feed
            assign a_feed[m] = feed_valid ? a_col[m*DATA_WIDTH +: DATA_WIDTH]
                                          : {DATA_WIDTH{1'b0}};
            assign b_feed[m] = feed_valid ? b_row[m*DATA_WIDTH +: DATA_WIDTH]
                                          : {DATA_WIDTH{1'b0}};
            // lane 0 has zero delay; lane m>0 is tapped m stages deep. The
            // (m==0?0:m-1) index keeps the untaken branch in bounds.
            assign a_left[m*DATA_WIDTH +: DATA_WIDTH] =
                (m == 0) ? a_feed[0] : a_sr[m][(m == 0) ? 0 : m-1];
            assign b_top [m*DATA_WIDTH +: DATA_WIDTH] =
                (m == 0) ? b_feed[0] : b_sr[m][(m == 0) ? 0 : m-1];
        end
    endgenerate

    assign en  = (state == S_RUN);
    assign clr = (state == S_SETUP) && !accum_q;
    assign busy = (state == S_SETUP) || (state == S_RUN);

    integer ii, dd;
    always @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            t          <= 16'd0;
            tc_q       <= 16'd0;
            klen_q     <= {KW{1'b0}};
            accum_q    <= 1'b0;
            done_pulse <= 1'b0;
            for (ii = 0; ii < N; ii = ii + 1)
                for (dd = 0; dd < N; dd = dd + 1) begin
                    a_sr[ii][dd] <= {DATA_WIDTH{1'b0}};
                    b_sr[ii][dd] <= {DATA_WIDTH{1'b0}};
                end
        end else begin
            done_pulse <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        klen_q  <= klen;
                        accum_q <= accum_mode;
                        tc_q    <= {{(16-KW){1'b0}}, klen} + 16'(2*N);
                        state   <= S_SETUP;
                    end
                end
                S_SETUP: begin
                    t <= 16'd0;
                    for (ii = 0; ii < N; ii = ii + 1)
                        for (dd = 0; dd < N; dd = dd + 1) begin
                            a_sr[ii][dd] <= {DATA_WIDTH{1'b0}};
                            b_sr[ii][dd] <= {DATA_WIDTH{1'b0}};
                        end
                    state <= S_RUN;
                end
                S_RUN: begin
                    // advance the skew network
                    for (ii = 0; ii < N; ii = ii + 1) begin
                        a_sr[ii][0] <= a_feed[ii];
                        b_sr[ii][0] <= b_feed[ii];
                        for (dd = 1; dd < N; dd = dd + 1) begin
                            a_sr[ii][dd] <= a_sr[ii][dd-1];
                            b_sr[ii][dd] <= b_sr[ii][dd-1];
                        end
                    end
                    if (t == tc_q - 16'd1) begin
                        state <= S_DONE;
                    end
                    t <= t + 16'd1;
                end
                S_DONE: begin
                    done_pulse <= 1'b1;
                    state      <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
