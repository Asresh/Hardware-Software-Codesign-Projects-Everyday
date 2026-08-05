// ============================================================================
// kvp_core.v - the paging engine's sequencer / block-table walker.
//
//   One batch = REQ_COUNT request words in memory.  For every word the core
//   walks the same path a paged-attention KV cache walks in software:
//
//     fetch request  ->  probe the translation cache
//                          hit   : emit {HIT, phys}
//                          miss  : read block_table[seq][idx]
//                                    valid   : fill the cache, emit phys
//                                    invalid : pop a free physical block,
//                                              write the block-table entry back,
//                                              fill the cache, emit {ALLOC,phys}
//     OP_FREE        ->  walk the sequence's entries, push each mapped block
//                        back on the free list, invalidate its cache entry and
//                        poison the block-table entry
//     OP_FLUSH       ->  invalidate the whole translation cache
//
//   Elasticity: every state advances only on `m_done` from the Wishbone master,
//   so wait states, a slow interconnect or a hung slave stretch the walk without
//   changing a single result - the output stream is a function of the request
//   stream alone, never of bus timing.
//
//   Throughput: while the result word of translation i is on the bus, the core
//   already presents the key of translation i+1 to the (combinational) cache
//   probe port and absorbs it in the same cycle if it hits.  A hot sequence
//   therefore retires one translation per bus transaction - one per clock
//   against a zero-wait-state slave - instead of one per two cycles.
//
//   Structure: a combinational block drives the bus request, the cache/free-list
//   strobes and the next state; a single clocked block owns the walk registers,
//   the statistics counters and the state.
// ============================================================================
`default_nettype none

module kvp_core #(
    parameter integer SEQ_W  = 12,
    parameter integer LOG_W  = 16,
    parameter integer PHYS_W = 24
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- control (from the register file) ----
    input  wire        start,
    input  wire        stat_clr,
    input  wire [31:0] req_base,
    input  wire [31:0] res_base,
    input  wire [31:0] req_count,
    input  wire [31:0] bt_base,
    input  wire [15:0] bt_stride,

    output reg         busy,
    output reg         done_pulse,
    output reg         err_oom,      // pulse: free list ran dry
    output reg         err_bus,      // pulse: bus error / watchdog

    // ---- statistics ----
    output reg  [31:0] stat_reqs,
    output reg  [31:0] stat_xlates,
    output reg  [31:0] stat_hits,
    output reg  [31:0] stat_misses,
    output reg  [31:0] stat_allocs,
    output reg  [31:0] stat_frees,
    output reg  [31:0] stat_errs,
    output reg  [31:0] res_words,
    output reg  [31:0] last_cyc,

    // ---- translation cache port ----
    output wire [SEQ_W+LOG_W-1:0] tlb_key,
    output wire                   tlb_touch,
    output wire                   tlb_fill,
    output wire [PHYS_W-1:0]      tlb_fill_phys,
    output wire                   tlb_inv,
    output wire                   tlb_flush,
    input  wire                   tlb_hit,
    input  wire [PHYS_W-1:0]      tlb_phys,

    // ---- free-list port ----
    output wire                   fl_push,
    output wire [PHYS_W-1:0]      fl_push_blk,
    output wire                   fl_pop,
    input  wire [PHYS_W-1:0]      fl_top,
    input  wire                   fl_empty,

    // ---- Wishbone master request port ----
    output wire                   m_req,
    output wire                   m_we,
    output wire [31:0]            m_addr,
    output wire [31:0]            m_wdata,
    input  wire                   m_done,
    input  wire                   m_err,
    input  wire [31:0]            m_rdata
);
    `include "kvp_defs.vh"

    localparam [3:0] S_IDLE    = 4'd0,
                     S_FETCH   = 4'd1,
                     S_XL      = 4'd2,
                     S_BT_RD   = 4'd3,
                     S_BT_WR   = 4'd4,
                     S_RES_WR  = 4'd5,
                     S_FREE_RD = 4'd6,
                     S_FREE_WR = 4'd7,
                     S_FINISH  = 4'd8;

    reg [3:0]        state;
    reg [31:0]       req_ptr, res_ptr, reqs_left;
    reg [3:0]        cur_op;
    reg [SEQ_W-1:0]  cur_seq;
    reg [31:0]       seq_row;      // cur_seq * bt_stride, computed once per request
    reg [16:0]       idx, n_items;
    reg              noalloc;
    reg [31:0]       result_q;
    reg [PHYS_W-1:0] alloc_blk;
    reg [PHYS_W-1:0] freed_cnt;
    reg [31:0]       cyc_cnt;

    // ---- decode of the request word currently on the bus (S_FETCH) ----
    wire [3:0]       w_op  = m_rdata[31:28];
    wire [SEQ_W-1:0] w_seq = m_rdata[16+SEQ_W-1:16];
    wire [15:0]      w_arg = m_rdata[15:0];

    // ---- walk bookkeeping ----
    wire [31:0] bt_addr    = bt_base + ((seq_row + {15'b0, idx}) << 2);
    wire [16:0] idx_next   = idx + 17'd1;
    wire        more_items = (cur_op == OP_RANGE) && (idx_next < n_items);
    wire        req_last   = (reqs_left == 32'd0);
    wire        bt_valid   = (m_rdata != BT_INVALID);

    // ---- transaction completion qualifiers ----
    wire fetch_ok   = (state == S_FETCH)   && m_done && !m_err;
    wire bt_rd_ok   = (state == S_BT_RD)   && m_done && !m_err;
    wire bt_wr_ok   = (state == S_BT_WR)   && m_done && !m_err;
    wire res_ok     = (state == S_RES_WR)  && m_done && !m_err;
    wire free_rd_ok = (state == S_FREE_RD) && m_done && !m_err;
    wire free_wr_ok = (state == S_FREE_WR) && m_done && !m_err;
    wire bus_fail   = m_done && m_err;

    // ---- allocation / probe decisions taken this cycle ----
    wire do_alloc   = bt_rd_ok && !bt_valid && !noalloc && !fl_empty;
    wire do_oom     = bt_rd_ok && !bt_valid && !noalloc &&  fl_empty;
    wire do_einval  = bt_rd_ok && !bt_valid &&  noalloc;
    wire xl_probe   = (state == S_XL);
    wire la_probe   = res_ok && more_items;          // lookahead absorb

    // ------------------------------------------------------------------
    // bus request (combinational: a zero-wait-state slave can ACK the same
    // cycle, giving one transaction per clock)
    // ------------------------------------------------------------------
    assign m_req = (state == S_FETCH)  || (state == S_BT_RD) ||
                   (state == S_BT_WR)  || (state == S_RES_WR) ||
                   (state == S_FREE_RD)|| (state == S_FREE_WR);
    assign m_we  = (state == S_BT_WR)  || (state == S_RES_WR) || (state == S_FREE_WR);

    assign m_addr  = (state == S_FETCH)  ? req_ptr :
                     (state == S_RES_WR) ? res_ptr : bt_addr;
    assign m_wdata = (state == S_RES_WR)  ? result_q :
                     (state == S_FREE_WR) ? BT_INVALID :
                                            {{(32-PHYS_W){1'b0}}, alloc_blk};

    // ------------------------------------------------------------------
    // translation-cache and free-list strobes
    // ------------------------------------------------------------------
    assign tlb_key       = (state == S_RES_WR) ? {cur_seq, idx_next[LOG_W-1:0]}
                                               : {cur_seq, idx[LOG_W-1:0]};
    assign tlb_touch     = ((xl_probe || la_probe) && tlb_hit);
    assign tlb_fill      = (bt_rd_ok && bt_valid) || bt_wr_ok;
    assign tlb_fill_phys = bt_wr_ok ? alloc_blk : m_rdata[PHYS_W-1:0];
    assign tlb_inv       = free_rd_ok && bt_valid;
    assign tlb_flush     = fetch_ok && (w_op == OP_FLUSH);

    assign fl_pop        = do_alloc;
    assign fl_push       = free_rd_ok && bt_valid;
    assign fl_push_blk   = m_rdata[PHYS_W-1:0];

    // ------------------------------------------------------------------
    // sequential: walk registers, statistics, state
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        done_pulse <= 1'b0;
        err_oom    <= 1'b0;
        err_bus    <= 1'b0;

        if (!rst_n) begin
            state <= S_IDLE; busy <= 1'b0;
            req_ptr <= 32'd0; res_ptr <= 32'd0; reqs_left <= 32'd0;
            cur_op <= 4'd0; cur_seq <= {SEQ_W{1'b0}}; seq_row <= 32'd0;
            idx <= 17'd0; n_items <= 17'd0; noalloc <= 1'b0;
            result_q <= 32'd0; alloc_blk <= {PHYS_W{1'b0}};
            freed_cnt <= {PHYS_W{1'b0}}; cyc_cnt <= 32'd0;
            res_words <= 32'd0; last_cyc <= 32'd0;
            stat_reqs <= 32'd0; stat_xlates <= 32'd0; stat_hits <= 32'd0;
            stat_misses <= 32'd0; stat_allocs <= 32'd0; stat_frees <= 32'd0;
            stat_errs <= 32'd0;
        end else begin
            if (stat_clr) begin
                stat_reqs   <= 32'd0; stat_xlates <= 32'd0; stat_hits  <= 32'd0;
                stat_misses <= 32'd0; stat_allocs <= 32'd0; stat_frees <= 32'd0;
                stat_errs   <= 32'd0;
            end
            if (busy) cyc_cnt <= cyc_cnt + 32'd1;

            // ---- statistics from this cycle's events ----
            if (fetch_ok)               stat_reqs   <= stat_reqs + 32'd1;
            if (xl_probe || la_probe)   stat_xlates <= stat_xlates + 32'd1;
            if ((xl_probe || la_probe) &&  tlb_hit) stat_hits   <= stat_hits + 32'd1;
            if ((xl_probe || la_probe) && !tlb_hit) stat_misses <= stat_misses + 32'd1;
            if (do_alloc)               stat_allocs <= stat_allocs + 32'd1;
            if (fl_push)                stat_frees  <= stat_frees + 32'd1;
            if (do_oom || do_einval || bus_fail ||
                (fetch_ok && (w_op > OP_FLUSH)))
                                        stat_errs   <= stat_errs + 32'd1;
            if (do_oom)                 err_oom     <= 1'b1;
            if (bus_fail)               err_bus     <= 1'b1;

            case (state)
            // ------------------------------------------------------------
            S_IDLE: if (start) begin
                req_ptr   <= req_base;
                res_ptr   <= res_base;
                reqs_left <= req_count;
                res_words <= 32'd0;
                cyc_cnt   <= 32'd0;
                busy      <= 1'b1;
                state     <= (req_count == 32'd0) ? S_FINISH : S_FETCH;
            end

            // ------------------------------------------------------------
            S_FETCH: if (m_done) begin
                if (m_err) begin
                    state <= S_FINISH;
                end else begin
                    req_ptr   <= req_ptr + 32'd4;
                    reqs_left <= reqs_left - 32'd1;
                    cur_op    <= w_op;
                    cur_seq   <= w_seq;
                    seq_row   <= w_seq * bt_stride;
                    noalloc   <= (w_op == OP_NOALLOC);
                    freed_cnt <= {PHYS_W{1'b0}};
                    case (w_op)
                    OP_XLATE, OP_NOALLOC: begin
                        idx     <= {1'b0, w_arg};
                        n_items <= 17'd1;
                        state   <= S_XL;
                    end
                    OP_RANGE: begin
                        idx     <= 17'd0;
                        n_items <= {1'b0, w_arg};
                        if (w_arg == 16'd0)          // degenerate: emits nothing
                            state <= (reqs_left == 32'd1) ? S_FINISH : S_FETCH;
                        else
                            state <= S_XL;
                    end
                    OP_FREE: begin
                        idx     <= 17'd0;
                        n_items <= {1'b0, w_arg};
                        if (w_arg == 16'd0) begin
                            result_q <= (32'd1 << (24+F_FREED_B));
                            state    <= S_RES_WR;
                        end else begin
                            state    <= S_FREE_RD;
                        end
                    end
                    OP_FLUSH: begin                  // tlb_flush pulses this cycle
                        idx      <= 17'd0;
                        n_items  <= 17'd1;
                        result_q <= (32'd1 << (24+F_FLUSHED_B));
                        state    <= S_RES_WR;
                    end
                    default: begin
                        idx      <= 17'd0;
                        n_items  <= 17'd1;
                        result_q <= (32'd1 << (24+F_EBADOP_B));
                        state    <= S_RES_WR;
                    end
                    endcase
                end
            end

            // ------------------------------------------------------------
            S_XL: begin
                if (tlb_hit) begin
                    result_q <= (32'd1 << (24+F_HIT_B)) | {8'd0, tlb_phys};
                    state    <= S_RES_WR;
                end else begin
                    state    <= S_BT_RD;
                end
            end

            // ------------------------------------------------------------
            S_BT_RD: if (m_done) begin
                if (m_err) begin
                    state <= S_FINISH;
                end else if (bt_valid) begin
                    result_q <= {8'd0, m_rdata[PHYS_W-1:0]};
                    state    <= S_RES_WR;
                end else if (noalloc) begin
                    result_q <= (32'd1 << (24+F_EINVAL_B));
                    state    <= S_RES_WR;
                end else if (fl_empty) begin
                    result_q <= (32'd1 << (24+F_EOOM_B));
                    n_items  <= idx_next;             // abandon the rest of the range
                    state    <= S_RES_WR;
                end else begin
                    alloc_blk <= fl_top;
                    state     <= S_BT_WR;
                end
            end

            // ------------------------------------------------------------
            S_BT_WR: if (m_done) begin
                if (m_err) begin
                    state <= S_FINISH;
                end else begin
                    result_q <= (32'd1 << (24+F_ALLOC_B)) | {8'd0, alloc_blk};
                    state    <= S_RES_WR;
                end
            end

            // ------------------------------------------------------------
            S_RES_WR: if (m_done) begin
                if (m_err) begin
                    state <= S_FINISH;
                end else begin
                    res_ptr   <= res_ptr + 32'd4;
                    res_words <= res_words + 32'd1;
                    if (more_items) begin
                        idx <= idx_next;
                        if (tlb_hit) begin
                            result_q <= (32'd1 << (24+F_HIT_B)) | {8'd0, tlb_phys};
                            state    <= S_RES_WR;
                        end else begin
                            state    <= S_BT_RD;
                        end
                    end else begin
                        state <= req_last ? S_FINISH : S_FETCH;
                    end
                end
            end

            // ------------------------------------------------------------
            S_FREE_RD: if (m_done) begin
                if (m_err) begin
                    state <= S_FINISH;
                end else if (bt_valid) begin
                    freed_cnt <= freed_cnt + 1'b1;    // pushed + invalidated above
                    state     <= S_FREE_WR;
                end else if (idx_next == n_items) begin
                    result_q <= (32'd1 << (24+F_FREED_B)) | {8'd0, freed_cnt};
                    state    <= S_RES_WR;
                end else begin
                    idx   <= idx_next;
                    state <= S_FREE_RD;
                end
            end

            S_FREE_WR: if (m_done) begin
                if (m_err) begin
                    state <= S_FINISH;
                end else if (idx_next == n_items) begin
                    result_q <= (32'd1 << (24+F_FREED_B)) | {8'd0, freed_cnt};
                    state    <= S_RES_WR;
                end else begin
                    idx   <= idx_next;
                    state <= S_FREE_RD;
                end
            end

            // ------------------------------------------------------------
            S_FINISH: begin
                busy       <= 1'b0;
                done_pulse <= 1'b1;
                last_cyc   <= cyc_cnt;
                state      <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // free_wr_ok is folded into the S_FREE_WR arm above; keep the wire alive for
    // waveform debug without an unused-signal warning.
    wire _unused_free_wr_ok = free_wr_ok;
endmodule

`default_nettype wire
