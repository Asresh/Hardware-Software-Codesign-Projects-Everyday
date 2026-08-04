// ============================================================================
// ann_regfile.v - MMIO control/status plane + AXI4-Stream ingress sequencer.
//
// This is the control half of the co-design.  Software programs the query
// window and the metric, writes START, and streams the database shard in over
// AXI4-Stream (P int8 elements per beat, TLAST on the final beat).  A small FSM
//   IDLE -> RUN -> FINISH
// gates ingress (tready = busy), counts the search span, validates that TLAST
// lands on a vector boundary (else it flags a truncated-shard error), lets the
// top-K network settle for one cycle in FINISH, then latches DONE and raises a
// sticky interrupt.  Cumulative statistics (vectors, beats) and the last-search
// cycle span are exposed as read-only registers; DONE/ERR/IRQ are cleared W1C.
// ============================================================================
`default_nettype none

module ann_regfile #(
    parameter integer D      = 64,
    parameter integer P      = 8,
    parameter integer K      = 8,
    parameter integer CHUNKS = D / P
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- MMIO register bus ----
    input  wire        reg_wr,
    input  wire        reg_rd,
    input  wire [7:0]  reg_addr,
    input  wire [31:0] reg_wdata,
    output reg  [31:0] reg_rdata,

    // ---- AXI4-Stream database ingress ----
    input  wire        s_tvalid,
    output wire        s_tready,
    input  wire [P*8-1:0] s_tdata,
    input  wire        s_tlast,

    // ---- to datapath ----
    output reg         clr,
    output wire        metric_o,
    output reg         q_wr,
    output wire [$clog2(D/4)-1:0] q_waddr,
    output wire [31:0] q_wdata,
    output wire        beat_valid,
    output wire [P*8-1:0] beat_data,

    // ---- from datapath ----
    input  wire        chunk_is_last,
    input  wire        emit_valid,
    input  wire [K*32-1:0] topk_score,
    input  wire [K*32-1:0] topk_id,

    output wire        irq
);
    `include "ann_reg.vh"

    // ---- state ----
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_FIN = 2'd2;
    reg [1:0] state;

    reg        busy, done, err, irq_flag, irq_en, metric_r, end_ok;
    reg [3:0]  errcode;
    reg [31:0] ndb;
    reg [31:0] stat_vecs, stat_beats, last_cyc, run_cyc;

    assign metric_o   = metric_r;
    assign s_tready   = busy;
    assign beat_valid = s_tvalid & s_tready;
    assign beat_data  = s_tdata;
    assign q_wdata    = reg_wdata;
    assign q_waddr    = (reg_addr - REG_QUERY_BASE);   // offset into query window
    assign irq        = irq_flag;

    wire beat_fire = beat_valid;
    wire last_fire = beat_fire & s_tlast;

    // ---- write / control path ----
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy <= 1'b0; done <= 1'b0; err <= 1'b0; irq_flag <= 1'b0;
            irq_en <= 1'b0; metric_r <= 1'b0; end_ok <= 1'b0; errcode <= 4'd0;
            ndb <= 32'd0; stat_vecs <= 32'd0; stat_beats <= 32'd0;
            last_cyc <= 32'd0; run_cyc <= 32'd0;
            clr <= 1'b0; q_wr <= 1'b0;
        end else begin
            clr  <= 1'b0;                     // default single-cycle pulses
            q_wr <= 1'b0;

            // MMIO writes
            if (reg_wr) begin
                case (reg_addr)
                    REG_CTRL: begin
                        irq_en <= reg_wdata[2];
                        if (reg_wdata[1]) begin        // SRESET clears stats
                            stat_vecs  <= 32'd0;
                            stat_beats <= 32'd0;
                        end
                        if (reg_wdata[0]) begin        // START
                            metric_r <= reg_wdata[8];
                            busy     <= 1'b1;
                            done     <= 1'b0;
                            err      <= 1'b0;
                            run_cyc  <= 32'd0;
                            clr      <= 1'b1;
                            state    <= S_RUN;
                        end
                    end
                    REG_NDB:     ndb <= reg_wdata;
                    REG_IRQ_ACK: begin done <= 1'b0; err <= 1'b0; irq_flag <= 1'b0; end
                    default: begin
                        if (reg_addr >= REG_QUERY_BASE &&
                            reg_addr <  REG_QUERY_BASE + (D/4)) begin
                            q_wr <= 1'b1;              // query window write
                        end
                    end
                endcase
            end

            // per-beat statistics
            if (beat_fire)  stat_beats <= stat_beats + 32'd1;
            if (emit_valid) stat_vecs  <= stat_vecs  + 32'd1;

            // search FSM
            case (state)
                S_RUN: begin
                    run_cyc <= run_cyc + 32'd1;
                    if (last_fire) begin
                        end_ok <= chunk_is_last;       // TLAST must end a vector
                        state  <= S_FIN;
                    end
                end
                S_FIN: begin                            // let top-K settle
                    busy     <= 1'b0;
                    last_cyc <= run_cyc;
                    if (end_ok) begin
                        done <= 1'b1;
                    end else begin
                        err     <= 1'b1;
                        errcode <= ERR_TRUNC;
                    end
                    irq_flag <= irq_flag | irq_en;
                    state    <= S_IDLE;
                end
                default: ;                              // S_IDLE
            endcase
        end
    end

    // ---- read path ----
    integer r;
    always @* begin
        reg_rdata = 32'd0;
        if (reg_addr == REG_STATUS)
            reg_rdata = {28'd0, irq_flag, busy, err, done};
        else if (reg_addr == REG_NDB)        reg_rdata = ndb;
        else if (reg_addr == REG_VERSION)    reg_rdata = ANN_VERSION;
        else if (reg_addr == REG_STAT_VECS)  reg_rdata = stat_vecs;
        else if (reg_addr == REG_STAT_BEATS) reg_rdata = stat_beats;
        else if (reg_addr == REG_LAST_CYC)   reg_rdata = last_cyc;
        else if (reg_addr == REG_ERRCODE)    reg_rdata = {28'd0, errcode};
        else if (reg_addr >= REG_SCORE_BASE && reg_addr < REG_SCORE_BASE + K)
            reg_rdata = topk_score[(reg_addr - REG_SCORE_BASE)*32 +: 32];
        else if (reg_addr >= REG_ID_BASE && reg_addr < REG_ID_BASE + K)
            reg_rdata = topk_id[(reg_addr - REG_ID_BASE)*32 +: 32];
    end
endmodule

`default_nettype wire
