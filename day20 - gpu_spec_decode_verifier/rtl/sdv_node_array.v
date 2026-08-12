// ===========================================================================
// sdv_node_array.v - on-chip draft-tree storage, broadcast port, parallel
//                    candidate evaluation and one-cycle structural validation.
//
// The whole tree lives in flops because every node has to be interrogated at
// once: on each step of the walk all N nodes simultaneously answer "is my
// parent the node we are standing on, and does my token pass the acceptance
// test", and the argmax tree reduces those N answers in the same cycle.  A RAM
// would serialise exactly the sweep this design exists to remove.
//
// Two things are precomputed as the nodes arrive rather than during the walk:
//
//   thr[j] = max(TH_ABS, (pmax[j] * TH_REL) >> 16)
//
// the "typical acceptance" floor a node imposes on its children when it is the
// one being extended.  Doing it at load time costs one multiplier used once
// per ingress beat and keeps the multiply out of the walk's critical path, so
// a path step stays a single cycle: broadcast mux -> compare -> argmax tree.
//
// Validation is three parallel reductions over the same flop array, so the
// structural check of an N-node tree is one cycle regardless of N.
// ===========================================================================
`default_nettype none
`include "sdv_defs.vh"

module sdv_node_array #(
    parameter integer N  = 64,
    parameter integer IW = 6            // clog2(N)
)(
    input  wire              clk,
    input  wire              rst_n,

    // ---- load port: one node record per accepted ingress beat -------------
    input  wire              wr_en,
    input  wire [IW-1:0]     wr_idx,
    input  wire [15:0]       wr_par,
    input  wire [31:0]       wr_tok,
    input  wire [31:0]       wr_pred,
    input  wire [15:0]       wr_score,
    input  wire [15:0]       wr_pmax,
    input  wire [15:0]       th_abs,     // latched job config
    input  wire [15:0]       th_rel,

    // ---- broadcast port: everything about the node being extended ---------
    input  wire [IW-1:0]     cur,
    output wire [31:0]       cur_pred,
    output wire [15:0]       cur_thr,
    output wire [31:0]       cur_tok,
    output wire [15:0]       cur_score,

    // ---- parallel candidate evaluation ------------------------------------
    input  wire [1:0]        mode,
    input  wire [15:0]       n_nodes,
    output wire [N-1:0]      cand,
    output wire [N*16-1:0]   score_flat,

    // ---- structural validation (combinational over the whole array) -------
    output wire              err_root,
    output wire              err_parent,
    output wire              err_self
);
    reg [15:0] par   [0:N-1];
    reg [31:0] tok   [0:N-1];
    reg [31:0] pred  [0:N-1];
    reg [15:0] score [0:N-1];
    reg [15:0] thr   [0:N-1];

    // ---- load-time threshold precompute ------------------------------------
    wire [31:0] rel_prod = wr_pmax * th_rel;          // Q0.16 x Q0.16
    wire [15:0] rel_q    = rel_prod[31:16];
    wire [15:0] thr_new  = (rel_q > th_abs) ? rel_q : th_abs;

    always @(posedge clk) begin
        if (wr_en) begin
            par  [wr_idx] <= wr_par;
            tok  [wr_idx] <= wr_tok;
            pred [wr_idx] <= wr_pred;
            score[wr_idx] <= wr_score;
            thr  [wr_idx] <= thr_new;
        end
    end

    // ---- broadcast muxes ---------------------------------------------------
    assign cur_pred  = pred [cur];
    assign cur_thr   = thr  [cur];
    assign cur_tok   = tok  [cur];
    assign cur_score = score[cur];

    // ---- per-node candidate predicate --------------------------------------
    // cand[j] = j is a live node, its parent is the node being extended, and
    //           its token passes the mode's acceptance test.
    genvar j;
    generate
        for (j = 0; j < N; j = j + 1) begin : ncell
            wire live   = (j < n_nodes) && (j != 0);
            wire ischild= (par[j] == {{(16-IW){1'b0}}, cur});
            wire g      = (tok[j]   == cur_pred);
            wire t      = (score[j] >= cur_thr);
            wire ok     = (mode == `SDV_MODE_GREEDY)  ? g :
                          (mode == `SDV_MODE_TYPICAL) ? t :
                          (mode == `SDV_MODE_BOTH)    ? (g && t) : (g || t);
            assign cand[j] = live && ischild && ok;
            assign score_flat[j*16 +: 16] = score[j];
        end
    endgenerate

    // ---- structural validation ---------------------------------------------
    wire [N-1:0] is_root, bad_par, bad_self;
    generate
        for (j = 0; j < N; j = j + 1) begin : chk
            wire live = (j < n_nodes) && (j != 0);
            assign is_root [j] = live && (par[j] == `SDV_ROOT_PARENT);
            assign bad_par [j] = live && (par[j] >= n_nodes);
            assign bad_self[j] = live && (par[j] == j);
        end
    endgenerate

    assign err_root   = (par[0] != `SDV_ROOT_PARENT) || (|is_root);
    // a node still carrying the root sentinel is reported as ERR_ROOT, which
    // outranks ERR_PARENT, so mask those out of the dangling-parent term
    assign err_parent = |(bad_par & ~is_root);
    assign err_self   = |bad_self;

endmodule
`default_nettype wire
