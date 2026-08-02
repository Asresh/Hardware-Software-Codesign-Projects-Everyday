// ============================================================================
// pretrade_risk_engine.v - top level.
//
// A line-rate pre-trade risk / market-access gateway (SEC 15c3-5 style). Every
// outbound order arrives as one 128-bit AXI4-Stream ingress beat, passes the
// six-gate risk pipeline, and leaves as one 128-bit AXI4-Stream decision beat
// (accept/reason + updated net position). An APB3 control plane programs the
// per-symbol / per-account limits, reads the statistics histogram, and fields
// the sticky violation interrupt.
//
//   host CPU --APB3--> risk_apb_regfile --cfg--> risk_tables
//                             |  ^stats/irq          ^  | async read / commit
//                             v  |                    |  v
//   order  --AXI4-Stream--> risk_pipeline ----------> decision --AXI4-Stream-->
// ============================================================================
`default_nettype none

module pretrade_risk_engine #(
    parameter integer SYM_N  = 32,
    parameter integer ACCT_N = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- AXI4-Stream order ingress ----
    input  wire [127:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,

    // ---- AXI4-Stream decision egress ----
    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,

    // ---- APB3 control/status ----
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [11:0] paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // ---- interrupt ----
    output wire        irq
);
    // ---- regfile <-> tables (config) ----
    wire        we_sym, we_acct;
    wire [15:0] sym_wr_idx, acct_wr_idx;
    wire [2:0]  sym_wr_word;
    wire [1:0]  acct_wr_word;
    wire [31:0] cfg_wdata;

    // ---- regfile <-> control ----
    wire kill_switch, engine_enable, irq_enable, soft_reset, clr_busy;

    // ---- pipeline <-> tables (read/commit) ----
    wire [15:0] rd_sym, rd_acct;
    wire [31:0] price_lo, price_hi, max_qty, pos_limit, max_msgs;
    wire [63:0] max_not;
    wire        sym_en, acct_en;
    wire signed [31:0] pos_rd;
    wire [31:0] cnt_rd;
    wire        pos_we, cnt_we;
    wire [15:0] pos_wr_sym, pos_wr_acct, cnt_wr_acct;
    wire signed [31:0] pos_wr_data;
    wire [31:0] cnt_wr_data;

    // ---- pipeline -> regfile (retire event) ----
    wire        ev_valid, ev_accept;
    wire [3:0]  ev_reason;
    wire [23:0] ev_oid;

    risk_apb_regfile #(.SYM_N(SYM_N), .ACCT_N(ACCT_N)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .prdata(prdata), .pready(pready), .pslverr(pslverr),
        .kill_switch(kill_switch), .engine_enable(engine_enable),
        .irq_enable(irq_enable), .soft_reset(soft_reset), .clr_busy(clr_busy),
        .we_sym(we_sym), .sym_wr_idx(sym_wr_idx), .sym_wr_word(sym_wr_word),
        .we_acct(we_acct), .acct_wr_idx(acct_wr_idx), .acct_wr_word(acct_wr_word),
        .cfg_wdata(cfg_wdata),
        .ev_valid(ev_valid), .ev_accept(ev_accept),
        .ev_reason(ev_reason), .ev_oid(ev_oid),
        .irq(irq)
    );

    risk_tables #(.SYM_N(SYM_N), .ACCT_N(ACCT_N)) u_tbl (
        .clk(clk), .rst_n(rst_n),
        .we_sym(we_sym), .sym_wr_idx(sym_wr_idx), .sym_wr_word(sym_wr_word),
        .we_acct(we_acct), .acct_wr_idx(acct_wr_idx), .acct_wr_word(acct_wr_word),
        .cfg_wdata(cfg_wdata),
        .clr(soft_reset), .clr_busy(clr_busy),
        .rd_sym(rd_sym), .rd_acct(rd_acct),
        .price_lo(price_lo), .price_hi(price_hi), .max_qty(max_qty),
        .max_not(max_not), .sym_en(sym_en),
        .pos_limit(pos_limit), .max_msgs(max_msgs), .acct_en(acct_en),
        .pos_rd(pos_rd), .cnt_rd(cnt_rd),
        .pos_we(pos_we), .pos_wr_sym(pos_wr_sym), .pos_wr_acct(pos_wr_acct),
        .pos_wr_data(pos_wr_data),
        .cnt_we(cnt_we), .cnt_wr_acct(cnt_wr_acct), .cnt_wr_data(cnt_wr_data)
    );

    risk_pipeline #(.SYM_N(SYM_N), .ACCT_N(ACCT_N)) u_pipe (
        .clk(clk), .rst_n(rst_n),
        .engine_enable(engine_enable), .kill_switch(kill_switch),
        .clr_busy(clr_busy),
        .s_tdata(s_axis_tdata), .s_tvalid(s_axis_tvalid),
        .s_tready(s_axis_tready), .s_tlast(s_axis_tlast),
        .m_tdata(m_axis_tdata), .m_tvalid(m_axis_tvalid),
        .m_tready(m_axis_tready), .m_tlast(m_axis_tlast),
        .rd_sym(rd_sym), .rd_acct(rd_acct),
        .price_lo(price_lo), .price_hi(price_hi), .max_qty(max_qty),
        .max_not(max_not), .sym_en(sym_en),
        .pos_limit(pos_limit), .max_msgs(max_msgs), .acct_en(acct_en),
        .pos_rd(pos_rd), .cnt_rd(cnt_rd),
        .pos_we(pos_we), .pos_wr_sym(pos_wr_sym), .pos_wr_acct(pos_wr_acct),
        .pos_wr_data(pos_wr_data),
        .cnt_we(cnt_we), .cnt_wr_acct(cnt_wr_acct), .cnt_wr_data(cnt_wr_data),
        .ev_valid(ev_valid), .ev_accept(ev_accept),
        .ev_reason(ev_reason), .ev_oid(ev_oid)
    );
endmodule

`default_nettype wire
