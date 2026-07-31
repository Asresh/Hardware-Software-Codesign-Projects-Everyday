// ============================================================================
// order_book_engine - CAM-based limit-order-book / BBO top level.
//
//   AXI4-Stream ingress  --> ob_msg_decode --> ob_cam (associative price map)
//                                                 |  level array
//                                    +------------+------------+
//                                    v                         v
//                        ob_bbo_reduce (bid,MAX)   ob_bbo_reduce (ask,MIN)
//                                    \                         /
//                                     +---> BBO latch + commit strobe + IRQ
//   MMIO (ob_regfile) <--> control / status / snapshot readback
//
// Two-stage pipeline: cycle t accepts a beat and the CAM computes the next
// level array (registered at end of t); cycle t+1 the reduction trees read the
// updated array and the BBO is latched. Sustains one message/clock with a
// 2-cycle message-to-BBO latency.
// ============================================================================
`default_nettype none
module order_book_engine #(
    parameter integer PW   = 16,
    parameter integer QW   = 24,
    parameter integer N    = 32,
    parameter integer MSGW = 64
) (
    input  wire              clk,
    input  wire              rst_n,

    // AXI4-Stream market-data ingress
    input  wire              s_tvalid,
    output wire              s_tready,
    input  wire [MSGW-1:0]   s_tdata,
    input  wire              s_tlast,

    // MMIO control / snapshot
    input  wire [7:0]        reg_addr,
    input  wire              reg_wr,
    input  wire              reg_rd,
    input  wire [31:0]       reg_wdata,
    output wire [31:0]       reg_rdata,
    output wire              irq,

    // direct BBO stream-out (for the testbench / low-latency consumers)
    output reg               bbo_commit,
    output reg               bbo_bid_valid,
    output reg  [PW-1:0]     bbo_bid_price,
    output reg  [QW-1:0]     bbo_bid_qty,
    output reg               bbo_ask_valid,
    output reg  [PW-1:0]     bbo_ask_price,
    output reg  [QW-1:0]     bbo_ask_qty,
    output reg  [31:0]       msg_count,
    output wire              overflow_o
);
    localparam integer CW = $clog2(N + 1);

    // ---- control plane ----
    wire soft_reset, irq_ack, irq_en;
    wire [CW-1:0] active_count;
    wire overflow;

    // ---- accept a beat unless resetting ----
    assign s_tready = rst_n & ~soft_reset;
    wire   accept   = s_tvalid & s_tready;

    // ---- decode ----
    wire [1:0]    d_op;
    wire          d_side;
    wire [PW-1:0] d_price;
    wire [QW-1:0] d_qty;
    ob_msg_decode #(.QW(QW), .PW(PW), .MSGW(MSGW)) u_dec (
        .beat(s_tdata), .op(d_op), .side(d_side), .price(d_price), .qty(d_qty)
    );

    // ---- associative price map ----
    wire [N-1:0]    lv_valid, lv_side;
    wire [N*PW-1:0] lv_price;
    wire [N*QW-1:0] lv_qty;
    ob_cam #(.PW(PW), .QW(QW), .N(N)) u_cam (
        .clk(clk), .rst_n(rst_n), .soft_reset(soft_reset), .ovf_clr(irq_ack),
        .upd(accept), .in_op(d_op), .in_side(d_side),
        .in_price(d_price), .in_qty(d_qty),
        .o_valid(lv_valid), .o_side(lv_side), .o_price(lv_price), .o_qty(lv_qty),
        .overflow(overflow), .active_count(active_count)
    );
    assign overflow_o = overflow;

    // ---- split levels by side for the two reduction trees ----
    //   bid tree sees asks as invalid, ask tree sees bids as invalid
    wire [N-1:0] bid_sel = lv_valid & ~lv_side;   // side==0 -> bid
    wire [N-1:0] ask_sel = lv_valid &  lv_side;   // side==1 -> ask

    wire            rb_v, ra_v;
    wire [PW-1:0]   rb_p, ra_p;
    wire [QW-1:0]   rb_q, ra_q;

    ob_bbo_reduce #(.PW(PW), .QW(QW), .N(N), .MODE(0)) u_bid (
        .in_valid(bid_sel), .in_price(lv_price), .in_qty(lv_qty),
        .out_valid(rb_v), .out_price(rb_p), .out_qty(rb_q)
    );
    ob_bbo_reduce #(.PW(PW), .QW(QW), .N(N), .MODE(1)) u_ask (
        .in_valid(ask_sel), .in_price(lv_price), .in_qty(lv_qty),
        .out_valid(ra_v), .out_price(ra_p), .out_qty(ra_q)
    );

    // ---- pipeline stage 2: latch BBO one cycle after the CAM update ----
    reg upd_d1;
    wire [PW+QW:0] new_bid = {rb_v, rb_p, rb_q};
    wire [PW+QW:0] new_ask = {ra_v, ra_p, ra_q};
    wire [PW+QW:0] old_bid = {bbo_bid_valid, bbo_bid_price, bbo_bid_qty};
    wire [PW+QW:0] old_ask = {bbo_ask_valid, bbo_ask_price, bbo_ask_qty};
    wire changed = (new_bid != old_bid) | (new_ask != old_ask);

    reg irq_pending;

    always @(posedge clk) begin
        if (!rst_n || soft_reset) begin
            upd_d1        <= 1'b0;
            bbo_commit    <= 1'b0;
            bbo_bid_valid <= 1'b0; bbo_bid_price <= {PW{1'b0}}; bbo_bid_qty <= {QW{1'b0}};
            bbo_ask_valid <= 1'b0; bbo_ask_price <= {PW{1'b0}}; bbo_ask_qty <= {QW{1'b0}};
            msg_count     <= 32'h0;
            irq_pending   <= 1'b0;
        end else begin
            upd_d1     <= accept;
            bbo_commit <= upd_d1;
            if (upd_d1) begin
                bbo_bid_valid <= rb_v; bbo_bid_price <= rb_p; bbo_bid_qty <= rb_q;
                bbo_ask_valid <= ra_v; bbo_ask_price <= ra_p; bbo_ask_qty <= ra_q;
                msg_count     <= msg_count + 32'h1;
            end
            // BBO-update interrupt
            if (irq_ack)                 irq_pending <= 1'b0;
            else if (upd_d1 & changed)   irq_pending <= 1'b1;
        end
    end

    wire busy = accept | upd_d1;
    assign irq = irq_en & irq_pending;

    // ---- register file ----
    ob_regfile #(.PW(PW), .QW(QW)) u_reg (
        .clk(clk), .rst_n(rst_n),
        .reg_addr(reg_addr), .reg_wr(reg_wr), .reg_rd(reg_rd),
        .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .busy(busy), .overflow(overflow), .irq_pending(irq_pending),
        .active_count({{(8-CW){1'b0}}, active_count}), .msg_count(msg_count),
        .bid_valid(bbo_bid_valid), .bid_price(bbo_bid_price), .bid_qty(bbo_bid_qty),
        .ask_valid(bbo_ask_valid), .ask_price(bbo_ask_price), .ask_qty(bbo_ask_qty),
        .irq_en(irq_en), .soft_reset(soft_reset), .irq_ack(irq_ack)
    );

    // silence unused
    wire _unused = &{1'b0, s_tlast, 1'b0};
endmodule
`default_nettype wire
