// ============================================================================
// arc_reduce_array.v - R-stage x P-lane systolic reduction array.
//
// Reduces R rank vectors element-wise into one P-wide result vector.  The R
// ranks form the *spatial* depth of a systolic chain; element-groups flow
// through it one per clock.  A group's R rank slices are presented together
// on `in_data`; classic systolic input skew delays rank r by r cycles so it
// meets the travelling partial at stage r, and each stage registers its PE
// output.  After an R-cycle fill the array retires one fully-reduced P-wide
// group every clock.
//
//   in_data layout (rank-major): rank r, lane p at bits [(r*P+p)*DW +: DW]
//   out_data           : lane p = reduce over r of in_data[r][p]
//   adv                : global advance; when low every register freezes so
//                        the pipeline stalls losslessly (memory wait states /
//                        egress backpressure) and stays bit-exact.
//   latency            : R cycles (in_valid -> out_valid)
// ============================================================================
`default_nettype none

module arc_reduce_array #(
    parameter integer R  = 4,
    parameter integer P  = 4,
    parameter integer DW = 32
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [1:0]           op,        // held stable while a group set streams
    input  wire                 adv,       // advance enable (freeze when low)
    input  wire                 in_valid,
    input  wire [R*P*DW-1:0]    in_data,
    output wire                 out_valid,
    output wire [P*DW-1:0]      out_data
);
    genvar s, p;

    // ---- per-rank input slices (this cycle) ----
    wire [P*DW-1:0] din_r [0:R-1];
    generate
        for (s = 0; s < R; s = s + 1) begin : g_slice
            assign din_r[s] = in_data[s*P*DW +: P*DW];
        end
    endgenerate

    // ---- skew shift registers: sr[r][j] = rank r delayed by (j+1) cycles ----
    reg [P*DW-1:0] sr [0:R-1][0:R-1];

    // ---- stage partials and the valid pipeline ----
    reg [P*DW-1:0] part [0:R-1];
    reg            vp   [0:R-1];

    // rank r delayed by exactly r cycles: r==0 -> this cycle; r>=1 -> sr[r][r-1]
    wire [P*DW-1:0] rank_del [0:R-1];
    assign rank_del[0] = din_r[0];
    generate
        for (s = 1; s < R; s = s + 1) begin : g_del
            assign rank_del[s] = sr[s][s-1];
        end
    endgenerate

    // ---- combinational PE array for stages 1..R-1 (stage 0 is a copy) ----
    wire [P*DW-1:0] stage_y [0:R-1];
    assign stage_y[0] = din_r[0];
    generate
        for (s = 1; s < R; s = s + 1) begin : g_stage
            for (p = 0; p < P; p = p + 1) begin : g_lane
                arc_reduce_pe #(.DW(DW)) pe (
                    .op (op),
                    .a  (part[s-1][p*DW +: DW]),      // travelling partial
                    .b  (rank_del[s][p*DW +: DW]),    // rank s, aligned in time
                    .y  (stage_y[s][p*DW +: DW])
                );
            end
        end
    endgenerate

    integer i, j;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < R; i = i + 1) begin
                part[i] <= {P*DW{1'b0}};
                vp[i]   <= 1'b0;
                for (j = 0; j < R; j = j + 1) sr[i][j] <= {P*DW{1'b0}};
            end
        end else if (adv) begin
            // skew chains
            for (i = 0; i < R; i = i + 1) begin
                sr[i][0] <= din_r[i];
                for (j = 1; j < R; j = j + 1) sr[i][j] <= sr[i][j-1];
            end
            // stage registers
            for (i = 0; i < R; i = i + 1) part[i] <= stage_y[i];
            // valid pipeline (R deep -> R-cycle latency)
            vp[0] <= in_valid;
            for (i = 1; i < R; i = i + 1) vp[i] <= vp[i-1];
        end
    end

    assign out_data  = part[R-1];
    assign out_valid = vp[R-1];
endmodule

`default_nettype wire
