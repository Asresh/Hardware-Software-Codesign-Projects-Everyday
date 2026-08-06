// ============================================================================
// kds_scoreboard - the associative dependency match.
//
// Every scoreboard slot holds a predecessor bitmask. On every tick all
// MAX_NODES masks are compared against the single retirement register in
// parallel:
//
//      ready[i] = valid[i] & ~issued[i] & ((dep[i] & ~done) == 0)
//
// so a node becomes eligible in the same cycle its last predecessor retires,
// independent of how many nodes the graph has. This is the whole reason the
// graph store is a CAM and not a RAM: a software runtime has to walk the node
// list to answer the same question, and that walk is O(N) per decision.
//
// The module is purely combinational; the retirement and issue registers live
// in kds_core.
// ============================================================================
`include "kds_defs.vh"

module kds_scoreboard #(
    parameter MAX_NODES = `KDS_MAX_NODES
) (
    input  wire [MAX_NODES*MAX_NODES-1:0] dep_flat,
    input  wire [MAX_NODES-1:0]           done_mask,
    input  wire [MAX_NODES-1:0]           issued_mask,
    input  wire [MAX_NODES-1:0]           valid_mask,
    output wire [MAX_NODES-1:0]           ready,
    output wire                           ready_any
);

    genvar i;
    generate
        for (i = 0; i < MAX_NODES; i = i + 1) begin : g_match
            wire [MAX_NODES-1:0] dep_i  = dep_flat[i*MAX_NODES +: MAX_NODES];
            wire                 unmet  = |(dep_i & ~done_mask);
            assign ready[i] = valid_mask[i] & ~issued_mask[i] & ~unmet;
        end
    endgenerate

    assign ready_any = |ready;

endmodule
