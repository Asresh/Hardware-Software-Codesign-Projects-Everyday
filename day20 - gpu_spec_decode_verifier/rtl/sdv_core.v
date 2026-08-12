// ===========================================================================
// sdv_core.v - ingress loader, structural check and the path walk.
//
// Four phases per job, and every cycle belongs to exactly one of them:
//
//   LOAD   one 128-bit node record per clock into the flop array; the
//          per-node acceptance threshold is computed on the way in
//   CHECK  one cycle: all structural checks resolve in parallel and are
//          priority-encoded (NNODES > ROOT > PARENT > SELF)
//   WALK   one clock per step.  All N nodes are tested against the node being
//          extended at once and the argmax tree names the winner in the same
//          cycle, so an accepted token costs one cycle whatever the fan-out.
//          The record of the node selected in cycle k is pushed in cycle k+1,
//          which keeps the winner mux out of the selection path.
//   TRAIL  one cycle: the trailer beat carrying the accepted count, the bonus
//          token (the target's own continuation from the last accepted node)
//          and the error/clamp status.
//
// A job therefore costs nodes + accepted + 3 cycles, and only the load term
// depends on the size of the tree.  Job configuration is latched on the first
// beat, so software programs the next job's mode and thresholds while the
// current one is still draining out of the egress FIFO.
// ===========================================================================
`default_nettype none
`include "sdv_defs.vh"

module sdv_core #(
    parameter integer N   = 64,
    parameter integer IW  = 6,
    parameter integer D   = 16,
    parameter integer DW  = 5           // bits to hold D (0..D)
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- job configuration, sampled on the first beat of a job ------------
    input  wire         en,
    input  wire [1:0]   cfg_mode,
    input  wire [15:0]  cfg_th_abs,
    input  wire [15:0]  cfg_th_rel,
    input  wire [15:0]  cfg_max_acc,

    // ---- AXI4-Stream ingress: one node record per beat --------------------
    input  wire         s_tvalid,
    output wire         s_tready,
    input  wire [127:0] s_tdata,
    input  wire         s_tlast,

    // ---- result FIFO ------------------------------------------------------
    output reg          fifo_push,
    output reg  [128:0] fifo_din,       // {tlast, beat}
    input  wire         fifo_empty,

    // ---- statistics strobes ----------------------------------------------
    output wire         st_busy,
    output wire         st_srcstall,
    output wire         st_bpstall,
    output reg          st_job_done,
    output reg          st_node_inc,
    output reg          st_accept_inc,
    output reg  [DW-1:0] st_accept_depth,
    output reg          st_err_job,
    output reg          st_clamp_job,
    output reg  [2:0]   st_errcode,
    output reg  [31:0]  st_last_cyc,
    output reg  [15:0]  st_last_acc,
    output wire [2:0]   dbg_state
);
    localparam [2:0] S_IDLE = 3'd0, S_LOAD = 3'd1, S_CHECK = 3'd2,
                     S_WALK = 3'd3, S_TRAIL = 3'd4;

    reg  [2:0]  state;
    reg  [16:0] cnt;                    // beats received this job
    reg         ovf;                    // more beats than the array holds
    reg  [1:0]  j_mode;
    reg  [15:0] j_abs, j_rel;
    reg  [DW-1:0] j_cap;
    reg  [IW-1:0] cur;
    reg  [DW-1:0] acc;
    reg         pending;
    reg         clamped;
    reg  [2:0]  err;
    reg  [31:0] job_cyc;

    assign dbg_state = state;

    // ---- ingress handshake -------------------------------------------------
    assign s_tready    = en && ((state == S_IDLE) || (state == S_LOAD));
    wire   beat        = s_tvalid && s_tready;
    assign st_busy     = (state != S_IDLE);
    assign st_srcstall = (state == S_LOAD) && !s_tvalid;
    assign st_bpstall  = s_tvalid && !s_tready;

    // ---- node record fields ------------------------------------------------
    wire [15:0] b_par   = s_tdata[15:0];
    wire [31:0] b_tok   = s_tdata[63:32];
    wire [31:0] b_pred  = s_tdata[95:64];
    wire [15:0] b_score = s_tdata[111:96];
    wire [15:0] b_pmax  = s_tdata[127:112];

    wire [15:0] nodes_field = (cnt[16] || (cnt[15:0] == 16'hFFFF)) ? 16'hFFFF
                                                                  : cnt[15:0];

    // ---- the tree store, broadcast port and parallel candidate mask --------
    wire [31:0]     cur_pred, cur_tok;
    wire [15:0]     cur_thr, cur_score;
    wire [N-1:0]    cand;
    wire [N*16-1:0] score_flat;
    wire            e_root, e_par, e_self;
    wire [15:0]     cfg_abs_now = (state == S_IDLE) ? cfg_th_abs : j_abs;
    wire [15:0]     cfg_rel_now = (state == S_IDLE) ? cfg_th_rel : j_rel;
    wire [1:0]      mode_now    = (state == S_IDLE) ? cfg_mode    : j_mode;

    sdv_node_array #(.N(N), .IW(IW)) u_arr (
        .clk(clk), .rst_n(rst_n),
        .wr_en   (beat && (cnt < N)),
        .wr_idx  (cnt[IW-1:0]),
        .wr_par  (b_par), .wr_tok(b_tok), .wr_pred(b_pred),
        .wr_score(b_score), .wr_pmax(b_pmax),
        .th_abs  (cfg_abs_now), .th_rel(cfg_rel_now),
        .cur     (cur),
        .cur_pred(cur_pred), .cur_thr(cur_thr),
        .cur_tok (cur_tok),  .cur_score(cur_score),
        .mode    (mode_now), .n_nodes(nodes_field),
        .cand    (cand), .score_flat(score_flat),
        .err_root(e_root), .err_parent(e_par), .err_self(e_self)
    );

    // ---- one-cycle winner selection ----------------------------------------
    wire          win_any;
    wire [IW-1:0] win_idx;
    wire [15:0]   win_val;

    sdv_argmax_tree #(.N(N), .W(16), .IW(IW)) u_tree (
        .valid(cand), .key(score_flat),
        .any(win_any), .idx(win_idx), .val(win_val)
    );

    wire [2:0] err_now = ovf                ? `SDV_ERR_NNODES :
                         e_root             ? `SDV_ERR_ROOT   :
                         e_par              ? `SDV_ERR_PARENT :
                         e_self             ? `SDV_ERR_SELF   : `SDV_ERR_NONE;

    wire at_cap = (acc == j_cap);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; cnt <= 0; ovf <= 1'b0; cur <= 0; acc <= 0;
            pending <= 1'b0; clamped <= 1'b0; err <= 0; job_cyc <= 0;
            j_mode <= 0; j_abs <= 0; j_rel <= 0; j_cap <= 0;
            fifo_push <= 1'b0; fifo_din <= 0;
            st_job_done <= 1'b0; st_node_inc <= 1'b0; st_accept_inc <= 1'b0;
            st_accept_depth <= 0; st_err_job <= 1'b0; st_clamp_job <= 1'b0;
            st_errcode <= 0; st_last_cyc <= 0; st_last_acc <= 0;
        end else begin
            fifo_push     <= 1'b0;
            st_job_done   <= 1'b0;
            st_node_inc   <= 1'b0;
            st_accept_inc <= 1'b0;
            st_err_job    <= 1'b0;
            st_clamp_job  <= 1'b0;

            if (state != S_IDLE) job_cyc <= job_cyc + 32'd1;

            case (state)
            // ---------------------------------------------------------------
            S_IDLE: if (beat) begin
                j_mode  <= cfg_mode;
                j_abs   <= cfg_th_abs;
                j_rel   <= cfg_th_rel;
                j_cap   <= (cfg_max_acc > D) ? D[DW-1:0]
                                             : cfg_max_acc[DW-1:0];
                cnt     <= 17'd1;
                ovf     <= 1'b0;
                clamped <= 1'b0;
                job_cyc <= 32'd1;
                st_node_inc <= 1'b1;
                state   <= s_tlast ? S_CHECK : S_LOAD;
            end
            // ---------------------------------------------------------------
            S_LOAD: if (beat) begin
                cnt <= cnt + 17'd1;
                st_node_inc <= 1'b1;
                if (cnt >= N) ovf <= 1'b1;   // one beat past the array
                if (s_tlast) state <= S_CHECK;
            end
            // ---------------------------------------------------------------
            // hold here until the previous job has fully left the FIFO, so the
            // walk that follows can never be stalled by egress backpressure
            S_CHECK: if (fifo_empty) begin
                err <= err_now;
                cur <= 0;
                acc <= 0;
                pending <= 1'b0;
                state <= (err_now != `SDV_ERR_NONE) ? S_TRAIL : S_WALK;
            end
            // ---------------------------------------------------------------
            S_WALK: begin
                // push the node selected on the previous cycle
                if (pending) begin
                    fifo_push        <= 1'b1;
                    fifo_din[128]    <= 1'b0;                        // not last
                    fifo_din[31:0]   <= {{(32-IW){1'b0}}, cur};      // node idx
                    fifo_din[63:32]  <= cur_tok;                     // token
                    fifo_din[95:64]  <= {16'h0, cur_score};          // score
                    fifo_din[127:96] <= {{(32-DW){1'b0}}, acc};      // depth
                    st_accept_inc    <= 1'b1;
                    st_accept_depth  <= acc;
                end
                pending <= 1'b0;

                if (win_any && !at_cap) begin
                    cur     <= win_idx;
                    acc     <= acc + 1'b1;
                    pending <= 1'b1;
                end else begin
                    clamped <= win_any && at_cap;
                    state   <= S_TRAIL;
                end
            end
            // ---------------------------------------------------------------
            S_TRAIL: begin
                fifo_push       <= 1'b1;
                fifo_din[128]   <= 1'b1;
                fifo_din[31:0]  <= (err != `SDV_ERR_NONE) ? 32'd0
                                                   : {{(32-DW){1'b0}}, acc};
                fifo_din[63:32] <= (err != `SDV_ERR_NONE) ? 32'd0 : cur_pred;
                fifo_din[95:64] <= {29'd0, err};
                fifo_din[127:96]<= {nodes_field,
                                    ((err == `SDV_ERR_NONE) && clamped)
                                        ? `SDV_FLAG_CLAMP : 16'h0};
                st_job_done  <= 1'b1;
                st_errcode   <= err;
                st_err_job   <= (err != `SDV_ERR_NONE);
                st_clamp_job <= (err == `SDV_ERR_NONE) && clamped;
                st_last_cyc  <= job_cyc + 32'd1;
                st_last_acc  <= (err != `SDV_ERR_NONE) ? 16'd0
                                                       : {{(16-DW){1'b0}}, acc};
                cnt   <= 17'd0;          // ready for the next job's first beat
                ovf   <= 1'b0;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
