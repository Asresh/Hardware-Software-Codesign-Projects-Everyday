// ============================================================================
// moe_topk.v - top-2 expert selection (argmax reduction).
//
// Combinationally reduces E signed Q8.8 logits to the two largest and their
// indices, using a strict-greater comparison so ties resolve to the lowest
// index (exactly the tie-break the C golden model uses).  The result feeds the
// softmax renormaliser; this build routes K=2 experts per token.
//
// The packed logit bus is indexed directly (not through a function) so the
// combinational block is correctly sensitive to it.
// ============================================================================
`default_nettype none

module moe_topk #(
    parameter integer E  = 8,
    parameter integer LW = 16,
    parameter integer IW = 8    // expert-index width in the record
) (
    input  wire [E*LW-1:0]      logits,   // packed: expert i in [LW*i +: LW]
    output reg  [IW-1:0]        top0_idx,
    output reg  signed [LW-1:0] top0_val,
    output reg  [IW-1:0]        top1_idx,
    output reg  signed [LW-1:0] top1_val
);
    integer i;
    reg signed [LW-1:0] v;

    always @* begin
        // ---- first maximum (lowest index on ties) ----
        top0_idx = {IW{1'b0}};
        top0_val = logits[0 +: LW];
        for (i = 1; i < E; i = i + 1) begin
            v = logits[i*LW +: LW];
            if (v > top0_val) begin
                top0_val = v;
                top0_idx = i[IW-1:0];
            end
        end
        // ---- second maximum, excluding top0_idx ----
        if (top0_idx == {IW{1'b0}}) begin
            top1_idx = {{(IW-1){1'b0}}, 1'b1};   // index 1
            top1_val = logits[LW +: LW];
        end else begin
            top1_idx = {IW{1'b0}};                // index 0
            top1_val = logits[0 +: LW];
        end
        for (i = 0; i < E; i = i + 1) begin
            if (i[IW-1:0] != top0_idx) begin
                v = logits[i*LW +: LW];
                if (v > top1_val) begin
                    top1_val = v;
                    top1_idx = i[IW-1:0];
                end
            end
        end
    end
endmodule

`default_nettype wire
