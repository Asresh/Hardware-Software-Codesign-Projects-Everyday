// ============================================================================
// ann_search_top.v - GPU vector-search (ANN) top-K engine, top level.
//
// Wires the control plane (ann_regfile: MMIO CSR + AXI4-Stream ingress FSM) to
// the datapath (ann_distance_array: P SIMD lanes + accumulator) and the
// selection network (ann_topk: streaming insertion top-K).  One database beat
// of P int8 elements is absorbed per clock; the K nearest / highest-scoring
// vectors of the shard are read back over the register file when the search
// completes and an interrupt is raised.
//
// Parameters:
//   D  vector dimensionality (int8 elements)
//   P  SIMD lanes = elements per AXI-Stream beat
//   K  number of results kept
// ============================================================================
`default_nettype none

module ann_search_top #(
    parameter integer D = 64,
    parameter integer P = 8,
    parameter integer K = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    // MMIO register bus
    input  wire        reg_wr,
    input  wire        reg_rd,
    input  wire [7:0]  reg_addr,
    input  wire [31:0] reg_wdata,
    output wire [31:0] reg_rdata,

    // AXI4-Stream database ingress
    input  wire        s_tvalid,
    output wire        s_tready,
    input  wire [P*8-1:0] s_tdata,
    input  wire        s_tlast,

    output wire        irq
);
    localparam integer CHUNKS = D / P;

    // control <-> datapath
    wire        clr, metric;
    wire        q_wr;
    wire [$clog2(D/4)-1:0] q_waddr;
    wire [31:0] q_wdata;
    wire        beat_valid;
    wire [P*8-1:0] beat_data;
    wire        chunk_is_last, emit_valid;
    wire signed [31:0] emit_score;
    wire [31:0] emit_id;
    wire [K*32-1:0] topk_score, topk_id;

    ann_regfile #(.D(D), .P(P), .K(K), .CHUNKS(CHUNKS)) u_reg (
        .clk(clk), .rst_n(rst_n),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr),
        .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tdata(s_tdata), .s_tlast(s_tlast),
        .clr(clr), .metric_o(metric),
        .q_wr(q_wr), .q_waddr(q_waddr), .q_wdata(q_wdata),
        .beat_valid(beat_valid), .beat_data(beat_data),
        .chunk_is_last(chunk_is_last), .emit_valid(emit_valid),
        .topk_score(topk_score), .topk_id(topk_id),
        .irq(irq)
    );

    ann_distance_array #(.D(D), .P(P), .DW(8), .CHUNKS(CHUNKS)) u_arr (
        .clk(clk), .rst_n(rst_n), .clr(clr), .metric(metric),
        .q_wr(q_wr), .q_waddr(q_waddr), .q_wdata(q_wdata),
        .beat_valid(beat_valid), .beat_data(beat_data),
        .chunk_is_last(chunk_is_last),
        .emit_valid(emit_valid), .emit_score(emit_score), .emit_id(emit_id)
    );

    ann_topk #(.K(K)) u_topk (
        .clk(clk), .rst_n(rst_n), .clr(clr), .metric(metric),
        .ins_valid(emit_valid), .ins_score(emit_score), .ins_id(emit_id),
        .o_score(topk_score), .o_id(topk_id)
    );
endmodule

`default_nettype wire
