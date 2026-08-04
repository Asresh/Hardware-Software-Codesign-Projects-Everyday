// ============================================================================
// ann_topk.v - streaming insertion-select top-K network.
//
// Holds K result slots sorted best->worst.  Each vector score arriving from the
// distance array is compared in parallel against every stored slot; because the
// list is kept sorted, the count of slots "at least as good" is exactly the
// insertion position.  If that position is inside the window the newcomer is
// inserted and the worse tail shifts down by one (dropping the last slot when
// the window is full).  One candidate is absorbed per clock.
//
// The stable tie rule (a stored slot that is equal to the newcomer stays ahead,
// since ids arrive in ascending order) matches the reference model exactly, so
// the top-K is reproducible to the bit for both metrics.
//   metric==0 (L2): smaller score is better
//   metric==1 (IP): larger  score is better
// ============================================================================
`default_nettype none

module ann_topk #(
    parameter integer K = 8
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                clr,          // start of search
    input  wire                metric,       // latched sentinel/compare sense
    input  wire                ins_valid,
    input  wire signed [31:0]  ins_score,
    input  wire [31:0]         ins_id,
    output wire [K*32-1:0]     o_score,
    output wire [K*32-1:0]     o_id
);
    localparam signed [31:0] SENT_L2 = 32'sh7FFFFFFF;   // +max distance
    localparam signed [31:0] SENT_IP = 32'sh80000000;   // -min dot

    reg signed [31:0] sc  [0:K-1];
    reg        [31:0] id  [0:K-1];
    reg               vld [0:K-1];

    wire signed [31:0] sent = metric ? SENT_IP : SENT_L2;

    // insertion position = number of valid slots at least as good as candidate
    reg [$clog2(K+1)-1:0] pos;
    integer j;
    always @* begin
        pos = 0;
        for (j = 0; j < K; j = j + 1) begin
            if (vld[j] &&
                ((metric && (sc[j] >= ins_score)) ||
                 (!metric && (sc[j] <= ins_score))))
                pos = pos + 1'b1;
        end
    end

    integer m;
    always @(posedge clk) begin
        if (!rst_n || clr) begin
            for (m = 0; m < K; m = m + 1) begin
                sc[m]  <= metric ? SENT_IP : SENT_L2;
                id[m]  <= 32'hFFFFFFFF;
                vld[m] <= 1'b0;
            end
        end else if (ins_valid && (pos < K)) begin
            for (m = 0; m < K; m = m + 1) begin
                if (m > pos) begin
                    sc[m]  <= sc[m-1];
                    id[m]  <= id[m-1];
                    vld[m] <= vld[m-1];
                end else if (m == pos) begin
                    sc[m]  <= ins_score;
                    id[m]  <= ins_id;
                    vld[m] <= 1'b1;
                end
            end
        end
    end

    genvar gi;
    generate
        for (gi = 0; gi < K; gi = gi + 1) begin : OUT
            assign o_score[gi*32 +: 32] = vld[gi] ? sc[gi] : sent;
            assign o_id[gi*32 +: 32]    = id[gi];
        end
    endgenerate
endmodule

`default_nettype wire
