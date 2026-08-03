// ============================================================================
// arc_dma_engine.v - descriptor-ring DMA + address generator for the
//                    all-reduce collective engine.
//
// Walks a ring of `desc_count` collective descriptors starting at `desc_base`.
// For each descriptor it reads {op, n, dst_base, src_base[0..R-1]}, then for
// every group of P elements it gathers R rank slices (a wide coalesced read),
// pumps them through the systolic reduction array, and scatters the P-wide
// result to the destination buffer with a per-lane tail mask.
//
// Result writes lag the gather by the array latency (R cycles); an addr/mask
// delay pipeline of matching depth keeps them aligned.  A single `adv` gate
// (= mem_ready while streaming) freezes the whole datapath - address gen,
// array and write pipeline - so memory wait states stall it losslessly and
// bit-exactly.  Descriptors are drained fully before the next begins so a
// change of reduction op never mixes inside the pipeline.
// ============================================================================
`default_nettype none

module arc_dma_engine #(
    parameter integer R  = 4,
    parameter integer P  = 4,
    parameter integer DW = 32,
    parameter integer AW = 24,
    parameter integer DESC_W = 16
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // ---- control (from register file) ----
    input  wire                 start,        // 1-cycle kick
    input  wire                 soft_reset,   // 1-cycle counter/state clear
    input  wire [AW-1:0]        desc_base,
    input  wire [15:0]          desc_count,

    // ---- status (to register file) ----
    output reg                  busy,
    output reg                  done_pulse,
    output reg                  err_pulse,
    output reg  [7:0]           errcode,
    output reg  [31:0]          completed,
    output reg  [31:0]          groups_total,
    output reg  [31:0]          words_total,

    // ---- memory master: descriptor read (whole descriptor, combinational) ----
    output reg                  desc_rd_en,
    output wire [AW-1:0]        desc_rd_addr,
    input  wire [DESC_W*32-1:0] desc_rd_data,

    // ---- memory master: source gather read (R x P words, combinational) ----
    output wire                 src_rd_en,
    output wire [R*AW-1:0]      src_rd_addr,
    input  wire [R*P*DW-1:0]    src_rd_data,

    // ---- memory master: result scatter write ----
    output wire                 res_wr_en,
    output wire [AW-1:0]        res_wr_addr,
    output wire [P-1:0]         res_wr_mask,
    output wire [P*DW-1:0]      res_wr_data,

    // ---- stall / backpressure ----
    input  wire                 mem_ready,

    // ---- systolic reduction array interface ----
    output wire [1:0]           arr_op,
    output wire                 arr_adv,
    output wire                 arr_in_valid,
    output wire [R*P*DW-1:0]    arr_in_data,
    input  wire                 arr_out_valid,
    input  wire [P*DW-1:0]      arr_out_data
);
    localparam [2:0] S_IDLE = 3'd0, S_FETCH = 3'd1, S_PARSE = 3'd2,
                     S_STREAM = 3'd3, S_DESC_DONE = 3'd4,
                     S_FINISH = 3'd5, S_ERR = 3'd6;

    // error codes (mirror ARC_ERR_* in sw/arc.h)
    localparam [7:0] ARC_ERR_INVAL_C = 8'd1, ARC_ERR_ZERON_C = 8'd2;

    reg [2:0]   state;
    reg [15:0]  d_index, desc_count_l;
    reg [AW-1:0] desc_base_l;

    // ---- latched descriptor fields ----
    reg [1:0]   op_l;
    reg [31:0]  n_l;
    reg [AW-1:0] dst_base_l;
    reg [AW-1:0] src_base_l [0:R-1];
    reg [31:0]  groups_l, g_cnt, wr_cnt;

    genvar gi;
    integer i;

    // ---- descriptor address ----
    assign desc_rd_addr = desc_base_l + d_index * DESC_W;

    // ---- descriptor field views (combinational, during S_FETCH/S_PARSE) ----
    wire [31:0] d_ctrl = desc_rd_data[0*32 +: 32];
    wire [31:0] d_n    = desc_rd_data[1*32 +: 32];
    wire [31:0] d_dst  = desc_rd_data[2*32 +: 32];
    wire        d_valid = d_ctrl[8];
    wire [1:0]  d_op    = d_ctrl[1:0];

    // ---- advance gate: datapath moves only while streaming and memory ready
    wire streaming = (state == S_STREAM);
    wire adv       = streaming & mem_ready;
    wire feeding   = streaming & (g_cnt < groups_l);

    assign arr_adv      = adv;
    assign arr_op       = op_l;
    assign arr_in_valid = adv & feeding;
    assign arr_in_data  = src_rd_data;
    assign src_rd_en    = arr_in_valid;

    // ---- current group source / dest addresses ----
    wire [31:0] grp_off = g_cnt * P;
    generate
        for (gi = 0; gi < R; gi = gi + 1) begin : g_src
            assign src_rd_addr[gi*AW +: AW] = src_base_l[gi] + grp_off[AW-1:0];
        end
    endgenerate
    wire [AW-1:0] cur_dst = dst_base_l + grp_off[AW-1:0];

    // ---- current tail mask (lane valid if global index < n) ----
    wire [P-1:0] cur_mask;
    generate
        for (gi = 0; gi < P; gi = gi + 1) begin : g_mask
            assign cur_mask[gi] = ((grp_off + gi) < n_l);
        end
    endgenerate

    // ---- write-delay pipeline (depth R, matches array latency) ----
    reg [AW-1:0] wr_addr_pipe [0:R-1];
    reg [P-1:0]  wr_mask_pipe [0:R-1];

    assign res_wr_en   = adv & arr_out_valid;
    assign res_wr_addr = wr_addr_pipe[R-1];
    assign res_wr_mask = wr_mask_pipe[R-1];
    assign res_wr_data = arr_out_data;

    // ---- popcount of the mask being written (for words_total) ----
    function [7:0] popc(input [P-1:0] m);
        integer k;
        begin
            popc = 0;
            for (k = 0; k < P; k = k + 1) popc = popc + m[k];
        end
    endfunction

    wire        last_write = res_wr_en & ((wr_cnt + 1) == groups_l);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; busy <= 0; done_pulse <= 0; err_pulse <= 0;
            errcode <= 0; completed <= 0; groups_total <= 0; words_total <= 0;
            desc_rd_en <= 0; d_index <= 0; g_cnt <= 0; wr_cnt <= 0;
        end else if (soft_reset) begin
            state <= S_IDLE; busy <= 0; done_pulse <= 0; err_pulse <= 0;
            errcode <= 0; completed <= 0; groups_total <= 0; words_total <= 0;
            desc_rd_en <= 0; d_index <= 0; g_cnt <= 0; wr_cnt <= 0;
        end else begin
            done_pulse <= 0; err_pulse <= 0; desc_rd_en <= 0;

            // write-delay pipeline shifts in lockstep with the array
            if (adv) begin
                wr_addr_pipe[0] <= cur_dst;
                wr_mask_pipe[0] <= cur_mask;
                for (i = 1; i < R; i = i + 1) begin
                    wr_addr_pipe[i] <= wr_addr_pipe[i-1];
                    wr_mask_pipe[i] <= wr_mask_pipe[i-1];
                end
            end

            // running result counters
            if (res_wr_en) begin
                groups_total <= groups_total + 1;
                words_total  <= words_total + popc(wr_mask_pipe[R-1]);
                wr_cnt       <= wr_cnt + 1;
            end
            if (adv & feeding) g_cnt <= g_cnt + 1;

            case (state)
            // ---------------------------------------------------------------
            S_IDLE: begin
                busy <= 0;
                if (start) begin
                    desc_base_l  <= desc_base;
                    desc_count_l <= desc_count;
                    d_index      <= 0;
                    busy         <= 1;
                    if (desc_count == 0) state <= S_FINISH;
                    else begin desc_rd_en <= 1; state <= S_FETCH; end
                end
            end
            // ---------------------------------------------------------------
            S_FETCH: begin           // descriptor data valid combinationally
                desc_rd_en <= 1;
                state      <= S_PARSE;
            end
            // ---------------------------------------------------------------
            S_PARSE: begin
                if (!d_valid) begin
                    errcode <= ARC_ERR_INVAL_C; state <= S_ERR;
                end else if (d_n == 0) begin
                    errcode <= ARC_ERR_ZERON_C; state <= S_ERR;
                end else begin
                    op_l       <= d_op;
                    n_l        <= d_n;
                    dst_base_l <= d_dst[AW-1:0];
                    for (i = 0; i < R; i = i + 1)
                        src_base_l[i] <= desc_rd_data[(3+i)*32 +: AW];
                    groups_l   <= (d_n + P - 1) / P;
                    g_cnt      <= 0;
                    wr_cnt     <= 0;
                    state      <= S_STREAM;
                end
            end
            // ---------------------------------------------------------------
            S_STREAM: begin
                if (last_write) state <= S_DESC_DONE;
            end
            // ---------------------------------------------------------------
            S_DESC_DONE: begin
                completed <= completed + 1;
                if ((d_index + 1) < desc_count_l) begin
                    d_index    <= d_index + 1;
                    desc_rd_en <= 1;
                    state      <= S_FETCH;
                end else state <= S_FINISH;
            end
            // ---------------------------------------------------------------
            S_FINISH: begin
                done_pulse <= 1; busy <= 0; state <= S_IDLE;
            end
            // ---------------------------------------------------------------
            S_ERR: begin
                err_pulse <= 1; busy <= 0; state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
