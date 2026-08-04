// ============================================================================
// ann_distance_array.v - P-lane SIMD score datapath.
//
// One AXI-Stream beat carries P int8 database elements (one dimension-chunk of
// a vector).  The P lanes score their chunk against the corresponding query
// elements, an adder tree sums the lanes, and an accumulator folds the CHUNKS
// beats of a vector into a full 32-bit score.  When the final chunk of a vector
// is consumed the score is emitted (with the running vector id) to the top-K
// network.  Everything advances only on an accepted beat, so ingress bubbles
// stall the pipeline losslessly and the result is bit-identical regardless of
// beat timing.
//
// The query vector lives in a small byte RAM written over the register file
// (4 elements per 32-bit word) before the search is launched.
// ============================================================================
`default_nettype none

module ann_distance_array #(
    parameter integer D      = 64,
    parameter integer P      = 8,
    parameter integer DW     = 8,
    parameter integer CHUNKS = D / P
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  clr,        // start of search: reset state
    input  wire                  metric,

    // query write port (from the register file)
    input  wire                  q_wr,
    input  wire [$clog2(D/4)-1:0] q_waddr,   // word index (4 elements/word)
    input  wire [31:0]           q_wdata,

    // beat ingress (already gated by tvalid & tready)
    input  wire                  beat_valid,
    input  wire [P*DW-1:0]       beat_data,

    // status / emit
    output wire                  chunk_is_last,
    output reg                   emit_valid,
    output reg signed [31:0]     emit_score,
    output reg [31:0]            emit_id
);
    localparam integer CW = (CHUNKS > 1) ? $clog2(CHUNKS) : 1;

    // ---- query byte RAM -----------------------------------------------------
    reg signed [DW-1:0] qmem [0:D-1];
    integer wi;
    always @(posedge clk) begin
        if (q_wr) begin
            for (wi = 0; wi < 4; wi = wi + 1)
                qmem[q_waddr*4 + wi] <= q_wdata[wi*8 +: 8];
        end
    end

    // ---- chunk / vector bookkeeping ----------------------------------------
    reg [CW-1:0]        chunk;
    reg [31:0]          vid;
    reg signed [31:0]   acc;

    assign chunk_is_last = (chunk == CHUNKS[CW-1:0] - 1'b1);

    // ---- P lanes + combinational adder tree --------------------------------
    wire signed [31:0] lane_y [0:P-1];
    genvar g;
    generate
        for (g = 0; g < P; g = g + 1) begin : LANE
            ann_distance_pe #(.DW(DW)) pe (
                .q     (qmem[chunk*P + g]),
                .x     (beat_data[g*DW +: DW]),
                .metric(metric),
                .y     (lane_y[g])
            );
        end
    endgenerate

    integer li;
    reg signed [31:0] partial;
    always @* begin
        partial = 32'sd0;
        for (li = 0; li < P; li = li + 1)
            partial = partial + lane_y[li];
    end

    wire signed [31:0] acc_next = (chunk == {CW{1'b0}}) ? partial : (acc + partial);

    always @(posedge clk) begin
        if (!rst_n || clr) begin
            chunk      <= {CW{1'b0}};
            vid        <= 32'd0;
            acc        <= 32'sd0;
            emit_valid <= 1'b0;
            emit_score <= 32'sd0;
            emit_id    <= 32'd0;
        end else if (beat_valid) begin
            if (chunk_is_last) begin
                emit_valid <= 1'b1;
                emit_score <= acc_next;
                emit_id    <= vid;
                vid        <= vid + 32'd1;
                chunk      <= {CW{1'b0}};
                acc        <= 32'sd0;
            end else begin
                emit_valid <= 1'b0;
                chunk      <= chunk + 1'b1;
                acc        <= acc_next;
            end
        end else begin
            emit_valid <= 1'b0;              // hold acc/chunk during bubbles
        end
    end
endmodule

`default_nettype wire
