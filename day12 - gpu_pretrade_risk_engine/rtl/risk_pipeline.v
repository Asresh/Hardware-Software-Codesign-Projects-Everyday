// ============================================================================
// risk_pipeline.v - the pre-trade risk datapath.
//
// A two-stage in-order pipeline that retires one order per clock:
//   Stage E (evaluate) : the registered order drives combinational async reads
//                        of the symbol/account config and the (account,symbol)
//                        position + accepted-count. Six heterogeneous risk
//                        gates evaluate fully in parallel; a priority encoder
//                        collapses them to a single accept / reason verdict.
//                        On accept, the new position and count commit the SAME
//                        cycle (1-cycle write-before-read keeps back-to-back
//                        same-key orders hazard-free).
//   Stage D (decision) : the verdict is registered onto the AXI4-Stream egress.
//
// Deterministic 2-cycle ingest->decision latency; result is independent of
// ingress bubbles / egress backpressure because all state is keyed on the
// order stream, never on the clock.
// ============================================================================
`default_nettype none

module risk_pipeline #(
    parameter integer SYM_N  = 32,
    parameter integer ACCT_N = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        engine_enable,
    input  wire        kill_switch,
    input  wire        clr_busy,

    // ---- AXI4-Stream order ingress ----
    input  wire [127:0] s_tdata,
    input  wire         s_tvalid,
    output wire         s_tready,
    input  wire         s_tlast,

    // ---- AXI4-Stream decision egress ----
    output wire [127:0] m_tdata,
    output wire         m_tvalid,
    input  wire         m_tready,
    output wire         m_tlast,

    // ---- table read (async) ----
    output wire [15:0] rd_sym,
    output wire [15:0] rd_acct,
    input  wire [31:0] price_lo,
    input  wire [31:0] price_hi,
    input  wire [31:0] max_qty,
    input  wire [63:0] max_not,
    input  wire        sym_en,
    input  wire [31:0] pos_limit,
    input  wire [31:0] max_msgs,
    input  wire        acct_en,
    input  wire signed [31:0] pos_rd,
    input  wire [31:0] cnt_rd,

    // ---- table commit write ----
    output wire        pos_we,
    output wire [15:0] pos_wr_sym,
    output wire [15:0] pos_wr_acct,
    output wire signed [31:0] pos_wr_data,
    output wire        cnt_we,
    output wire [15:0] cnt_wr_acct,
    output wire [31:0] cnt_wr_data,

    // ---- decision event to the register file (once per retired order) ----
    output wire        ev_valid,
    output wire        ev_accept,
    output wire [3:0]  ev_reason,
    output wire [23:0] ev_oid
);
    localparam [3:0] REJ_NONE=0, REJ_KILL=1, REJ_RANGE=2, REJ_HALT=3,
                     REJ_PRICEBAND=4, REJ_MAXQTY=5, REJ_NOTIONAL=6,
                     REJ_POSLIMIT=7, REJ_MSGCOUNT=8;

    // ---- stage E registers (order under evaluation) ----
    reg         e_valid;
    reg  [15:0] e_sym, e_acct;
    reg  [31:0] e_price, e_qty;
    reg  [23:0] e_oid;
    reg         e_side;

    // ---- stage D registers (decision on egress) ----
    reg         d_valid;
    reg  [23:0] d_oid;
    reg         d_accept;
    reg  [3:0]  d_reason;
    reg  [15:0] d_sym, d_acct;
    reg  [31:0] d_pos;

    // ---- flow control ----
    wire stall = d_valid & ~m_tready;          // egress backpressure holds all
    wire adv   = ~stall;
    assign s_tready = adv & ~clr_busy & engine_enable;
    wire   s_fire   = s_tvalid & s_tready;

    // ---- combinational risk gates on the stage-E order ----
    assign rd_sym  = e_sym;
    assign rd_acct = e_acct;

    wire in_range = (e_sym < SYM_N) && (e_acct < ACCT_N);

    wire [63:0] notional = {32'b0, e_price} * {32'b0, e_qty};
    wire signed [63:0] pos_ext = {{32{pos_rd[31]}}, pos_rd};
    wire signed [63:0] sqty    = e_side ? -$signed({32'b0, e_qty})
                                        :  $signed({32'b0, e_qty});
    wire signed [63:0] newpos  = pos_ext + sqty;
    wire [63:0] abspos = newpos[63] ? (~newpos + 64'd1) : newpos;

    wire c_kill  = kill_switch;
    wire c_range = ~in_range;
    wire c_halt  = in_range && (~sym_en || ~acct_en);
    wire c_price = in_range && (e_price < price_lo || e_price > price_hi);
    wire c_qty   = in_range && (e_qty == 32'd0 || e_qty > max_qty);
    wire c_not   = in_range && (notional > max_not);
    wire c_pos   = in_range && (abspos > {32'b0, pos_limit});
    wire c_msg   = in_range && (cnt_rd >= max_msgs);

    wire [3:0] reason =
        c_kill  ? REJ_KILL      :
        c_range ? REJ_RANGE     :
        c_halt  ? REJ_HALT      :
        c_price ? REJ_PRICEBAND :
        c_qty   ? REJ_MAXQTY    :
        c_not   ? REJ_NOTIONAL  :
        c_pos   ? REJ_POSLIMIT  :
        c_msg   ? REJ_MSGCOUNT  : REJ_NONE;
    wire accept  = (reason == REJ_NONE);
    wire commit  = adv & e_valid & accept;

    // ---- commit writes (same cycle as evaluate) ----
    assign pos_we      = commit;
    assign pos_wr_sym  = e_sym;
    assign pos_wr_acct = e_acct;
    assign pos_wr_data = newpos[31:0];
    assign cnt_we      = commit;
    assign cnt_wr_acct = e_acct;
    assign cnt_wr_data = cnt_rd + 32'd1;

    // ---- pipeline registers ----
    always @(posedge clk) begin
        if (!rst_n) begin
            e_valid <= 1'b0;
            d_valid <= 1'b0;
        end else if (adv) begin
            // stage E -> stage D
            d_valid  <= e_valid;
            d_oid    <= e_oid;
            d_accept <= accept;
            d_reason <= reason;
            d_sym    <= e_sym;
            d_acct   <= e_acct;
            // accepted -> new position; in-range reject -> current position;
            // out-of-range reject -> 0 (no addressable position)
            d_pos    <= accept ? newpos[31:0] : (in_range ? pos_rd : 32'd0);

            // ingress -> stage E
            e_valid <= s_fire;
            if (s_fire) begin
                e_sym   <= s_tdata[15:0];
                e_acct  <= s_tdata[31:16];
                e_price <= s_tdata[63:32];
                e_qty   <= s_tdata[95:64];
                e_oid   <= s_tdata[119:96];
                e_side  <= s_tdata[120];
            end
        end
    end

    // ---- egress packing ----
    assign m_tvalid = d_valid;
    assign m_tlast  = 1'b1;
    assign m_tdata  = { 32'b0,
                        d_pos,                       // [95:64]
                        8'b0, d_acct[7:0],           // [63:48]
                        d_sym,                       // [47:32]
                        3'b0, d_reason,              // [31:25]
                        d_accept,                    // [24]
                        d_oid };                     // [23:0]

    // ---- retire event ----
    assign ev_valid  = m_tvalid & m_tready;
    assign ev_accept = d_accept;
    assign ev_reason = d_reason;
    assign ev_oid    = d_oid;
endmodule

`default_nettype wire
