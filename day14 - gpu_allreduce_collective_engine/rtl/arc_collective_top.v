// ============================================================================
// arc_collective_top.v - GPU multi-GPU all-reduce collective engine (top).
//
// Ties together the three datapath blocks:
//   arc_regfile      MMIO control/status + sticky done/err interrupt
//   arc_dma_engine   descriptor-ring walk + address generation + scatter
//   arc_reduce_array R-stage x P-lane systolic reduction array
//
// Exposes an MMIO register bus to the host, a wide memory master (descriptor
// read + R-way source gather + P-wide result scatter), a stall input for
// memory wait states, and the completion/error interrupt line.
// ============================================================================
`default_nettype none

module arc_collective_top #(
    parameter integer R      = 4,
    parameter integer P      = 4,
    parameter integer DW     = 32,
    parameter integer AW     = 24,
    parameter integer DESC_W = 16
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // ---- MMIO register bus ----
    input  wire                 reg_wr,
    input  wire                 reg_rd,
    input  wire [7:0]           reg_addr,
    input  wire [31:0]          reg_wdata,
    output wire [31:0]          reg_rdata,

    // ---- memory master ----
    output wire                 desc_rd_en,
    output wire [AW-1:0]        desc_rd_addr,
    input  wire [DESC_W*32-1:0] desc_rd_data,
    output wire                 src_rd_en,
    output wire [R*AW-1:0]      src_rd_addr,
    input  wire [R*P*DW-1:0]    src_rd_data,
    output wire                 res_wr_en,
    output wire [AW-1:0]        res_wr_addr,
    output wire [P-1:0]         res_wr_mask,
    output wire [P*DW-1:0]      res_wr_data,

    // ---- stall / backpressure ----
    input  wire                 mem_ready,

    // ---- interrupt ----
    output wire                 irq
);
    // ---- regfile <-> dma ----
    wire        start, soft_reset, irq_en;
    wire [AW-1:0] desc_base;
    wire [15:0]   desc_count;
    wire          busy, done_pulse, err_pulse;
    wire [7:0]    errcode;
    wire [31:0]   completed, groups_total, words_total;

    // ---- dma <-> array ----
    wire [1:0]         arr_op;
    wire               arr_adv, arr_in_valid, arr_out_valid;
    wire [R*P*DW-1:0]  arr_in_data;
    wire [P*DW-1:0]    arr_out_data;

    arc_regfile #(.R(R), .P(P), .DW(DW), .AW(AW)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr),
        .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .start(start), .soft_reset(soft_reset), .irq_en(irq_en),
        .desc_base(desc_base), .desc_count(desc_count),
        .busy(busy), .done_pulse(done_pulse), .err_pulse(err_pulse),
        .errcode(errcode), .completed(completed),
        .groups_total(groups_total), .words_total(words_total),
        .irq(irq)
    );

    arc_dma_engine #(.R(R), .P(P), .DW(DW), .AW(AW), .DESC_W(DESC_W)) u_dma (
        .clk(clk), .rst_n(rst_n),
        .start(start), .soft_reset(soft_reset),
        .desc_base(desc_base), .desc_count(desc_count),
        .busy(busy), .done_pulse(done_pulse), .err_pulse(err_pulse),
        .errcode(errcode), .completed(completed),
        .groups_total(groups_total), .words_total(words_total),
        .desc_rd_en(desc_rd_en), .desc_rd_addr(desc_rd_addr),
        .desc_rd_data(desc_rd_data),
        .src_rd_en(src_rd_en), .src_rd_addr(src_rd_addr),
        .src_rd_data(src_rd_data),
        .res_wr_en(res_wr_en), .res_wr_addr(res_wr_addr),
        .res_wr_mask(res_wr_mask), .res_wr_data(res_wr_data),
        .mem_ready(mem_ready),
        .arr_op(arr_op), .arr_adv(arr_adv),
        .arr_in_valid(arr_in_valid), .arr_in_data(arr_in_data),
        .arr_out_valid(arr_out_valid), .arr_out_data(arr_out_data)
    );

    arc_reduce_array #(.R(R), .P(P), .DW(DW)) u_arr (
        .clk(clk), .rst_n(rst_n),
        .op(arr_op), .adv(arr_adv),
        .in_valid(arr_in_valid), .in_data(arr_in_data),
        .out_valid(arr_out_valid), .out_data(arr_out_data)
    );
endmodule

`default_nettype wire
