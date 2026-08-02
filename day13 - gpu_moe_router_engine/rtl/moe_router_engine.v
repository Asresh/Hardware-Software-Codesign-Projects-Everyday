// ============================================================================
// moe_router_engine.v - top level: GPU Mixture-of-Experts top-k routing engine.
//
//   One 128-bit AXI4-Stream beat carries a token's E packed Q8.8 expert logits.
//   The engine selects the top-K experts, evaluates a fixed-point softmax over
//   the selected set, renormalises to Q.16 gate weights, applies per-expert
//   capacity (dropping over-cap slots), and emits a 128-bit dispatch record on
//   the egress stream.  An AXI4-Lite file programs capacity/IRQ and exposes the
//   routing statistics; a sticky interrupt fires on any over-capacity drop.
//
//   The whole datapath is one elastic pipeline: a single advance signal `adv`
//   (deasserted only when the egress beat is stalled) clock-enables every stage
//   and both dividers, so the design stalls losslessly under egress backpressure
//   and remains bit-exact regardless of ingress bubbles.  Fixed latency;
//   one token per clock when unstalled.
// ============================================================================
`default_nettype none

module moe_router_engine #(
    parameter integer E       = 8,      // number of experts
    parameter integer K       = 2,      // top-k routed experts (record fixed 2)
    parameter integer LOGIT_W = 16,     // signed Q8.8 logit width
    parameter integer IW      = 8,      // expert-index field width
    parameter integer EXPW    = 18,     // exp value width
    parameter integer FRAC    = 16,     // softmax fraction bits
    parameter integer NUMW    = 34,     // divider dividend width (EXPW+FRAC)
    parameter integer DIVW    = 18,     // divider divisor width
    parameter integer LUTN    = 257
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // ingress AXI4-Stream : one token (E packed logits) per beat
    input  wire [E*LOGIT_W-1:0] s_axis_tdata,
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire                 s_axis_tlast,

    // egress AXI4-Stream : one dispatch record per token
    output wire [127:0]         m_axis_tdata,
    output wire                 m_axis_tvalid,
    input  wire                 m_axis_tready,
    output wire                 m_axis_tlast,

    // AXI4-Lite control/status
    input  wire [11:0]          awaddr,
    input  wire                 awvalid,
    output wire                 awready,
    input  wire [31:0]          wdata,
    input  wire [3:0]           wstrb,
    input  wire                 wvalid,
    output wire                 wready,
    output wire [1:0]           bresp,
    output wire                 bvalid,
    input  wire                 bready,
    input  wire [11:0]          araddr,
    input  wire                 arvalid,
    output wire                 arready,
    output wire [31:0]          rdata,
    output wire [1:0]           rresp,
    output wire                 rvalid,
    input  wire                 rready,

    output wire                 irq
);
    localparam integer DLAT = NUMW + 1;             // divider latency
    localparam integer SBW  = 1 + 16 + IW + IW;     // {last,tid,e0,e1}

    // ---- control plane ----
    wire        en, irq_en, soft_rst;
    wire [31:0] cap;

    // ---- pipeline advance ----
    wire out_valid;
    wire stall = out_valid & ~m_axis_tready;
    wire adv   = ~stall;
    assign s_axis_tready = adv & en;
    wire in_fire = s_axis_tvalid & s_axis_tready;

    // ---- stage 0 : ingest ----
    reg                  s0_v, s0_last;
    reg [E*LOGIT_W-1:0]  s0_logits;
    reg [15:0]           s0_tid, tid;
    always @(posedge clk) begin
        if (!rst_n) begin
            s0_v <= 1'b0; s0_last <= 1'b0; s0_logits <= 0; s0_tid <= 0; tid <= 0;
        end else begin
            if (adv) begin
                s0_v      <= in_fire;
                s0_logits <= s_axis_tdata;
                s0_last   <= s_axis_tlast;
                s0_tid    <= tid;
            end
            if (soft_rst)                tid <= 16'd0;   // new stream/batch
            else if (adv && in_fire)     tid <= tid + 16'd1;
        end
    end

    // ---- top-K selection (combinational) ----
    wire [IW-1:0]           t0_idx, t1_idx;
    wire signed [LOGIT_W-1:0] t0_val, t1_val;
    moe_topk #(.E(E), .LW(LOGIT_W), .IW(IW)) u_topk (
        .logits(s0_logits),
        .top0_idx(t0_idx), .top0_val(t0_val),
        .top1_idx(t1_idx), .top1_val(t1_val)
    );

    // ---- stage 1 : selection registers ----
    reg                      s1_v, s1_last;
    reg [15:0]               s1_tid;
    reg [IW-1:0]             s1_e0, s1_e1;
    reg signed [LOGIT_W-1:0] s1_max, s1_t1;
    always @(posedge clk) begin
        if (!rst_n) begin
            s1_v <= 1'b0; s1_last <= 1'b0; s1_tid <= 0;
            s1_e0 <= 0; s1_e1 <= 0; s1_max <= 0; s1_t1 <= 0;
        end else if (adv) begin
            s1_v    <= s0_v;
            s1_last <= s0_last;
            s1_tid  <= s0_tid;
            s1_e0   <= t0_idx;  s1_e1 <= t1_idx;
            s1_max  <= t0_val;  s1_t1 <= t1_val;
        end
    end

    // ---- softmax numerators (combinational) ----
    wire [NUMW-1:0] sm_num0, sm_num1;
    wire [DIVW-1:0] sm_den;
    moe_softmax #(.LW(LOGIT_W), .EXPW(EXPW), .NUMW(NUMW), .DIVW(DIVW), .LUTN(LUTN))
    u_softmax (
        .top0_val(s1_max), .top1_val(s1_t1),
        .num0(sm_num0), .num1(sm_num1), .den(sm_den)
    );

    // ---- stage 2 : softmax registers (divider inputs) ----
    reg              s2_v, s2_last;
    reg [15:0]       s2_tid;
    reg [IW-1:0]     s2_e0, s2_e1;
    reg [NUMW-1:0]   s2_num0, s2_num1;
    reg [DIVW-1:0]   s2_den;
    always @(posedge clk) begin
        if (!rst_n) begin
            s2_v <= 1'b0; s2_last <= 1'b0; s2_tid <= 0;
            s2_e0 <= 0; s2_e1 <= 0; s2_num0 <= 0; s2_num1 <= 0; s2_den <= 0;
        end else if (adv) begin
            s2_v    <= s1_v;
            s2_last <= s1_last;
            s2_tid  <= s1_tid;
            s2_e0   <= s1_e0;  s2_e1 <= s1_e1;
            s2_num0 <= sm_num0; s2_num1 <= sm_num1; s2_den <= sm_den;
        end
    end

    // ---- two pipelined dividers : Q.16 gate weights ----
    wire [NUMW-1:0] quo0, quo1;
    wire            dv0, dv1;
    moe_divu #(.NUMW(NUMW), .DIVW(DIVW)) u_div0 (
        .clk(clk), .rst_n(rst_n), .en(adv), .in_valid(s2_v),
        .num(s2_num0), .den(s2_den), .out_valid(dv0), .quo(quo0)
    );
    moe_divu #(.NUMW(NUMW), .DIVW(DIVW)) u_div1 (
        .clk(clk), .rst_n(rst_n), .en(adv), .in_valid(s2_v),
        .num(s2_num1), .den(s2_den), .out_valid(dv1), .quo(quo1)
    );

    // ---- sideband delay line, aligned to the divider latency ----
    reg [SBW-1:0] sb [0:DLAT-1];
    integer di;
    wire [SBW-1:0] sb_in = {s2_last, s2_tid, s2_e0, s2_e1};
    always @(posedge clk) begin
        if (adv) begin
            sb[0] <= sb_in;
            for (di = 1; di < DLAT; di = di + 1) sb[di] <= sb[di-1];
        end
    end
    wire [SBW-1:0]  sb_out = sb[DLAT-1];
    wire            r_last = sb_out[SBW-1];
    wire [15:0]     r_tid  = sb_out[2*IW +: 16];
    wire [IW-1:0]   r_e0   = sb_out[IW +: IW];
    wire [IW-1:0]   r_e1   = sb_out[0 +: IW];

    assign out_valid = dv0;

    // ---- capacity + statistics ----
    wire        ov0, ov1, ovf_pulse;
    wire [1:0]  routed;
    wire [E*32-1:0] load_flat;
    wire [31:0] st_tokens, st_routed, st_overflow;
    wire        fire = out_valid & m_axis_tready;
    moe_capacity #(.E(E), .IW(IW)) u_cap (
        .clk(clk), .rst_n(rst_n), .clr(soft_rst), .cap(cap),
        .fire(fire), .e0(r_e0), .e1(r_e1),
        .ov0(ov0), .ov1(ov1), .routed(routed), .ovf_pulse(ovf_pulse),
        .load_flat(load_flat),
        .tokens(st_tokens), .routed_tot(st_routed), .overflow_tot(st_overflow)
    );

    // ---- pack the dispatch record ----
    wire [17:0] w0 = ov0 ? 18'd0 : quo0[17:0];
    wire [17:0] w1 = ov1 ? 18'd0 : quo1[17:0];
    wire [31:0] lane0 = {16'b0, r_tid};
    wire [31:0] lane1 = {ov0, 5'b0, r_e0, w0};
    wire [31:0] lane2 = {ov1, 5'b0, r_e1, w1};
    wire [31:0] lane3 = {24'b0, 6'b0, routed};
    assign m_axis_tdata  = {lane3, lane2, lane1, lane0};
    assign m_axis_tvalid = out_valid;
    assign m_axis_tlast  = r_last;

    // ---- AXI4-Lite register file ----
    moe_axi_regfile #(.E(E), .K(K), .LOGIT_W(LOGIT_W)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .en(en), .irq_en(irq_en), .soft_rst(soft_rst), .cap(cap), .irq(irq),
        .ovf_pulse(ovf_pulse), .tokens(st_tokens),
        .overflow_tot(st_overflow), .routed_tot(st_routed), .load_flat(load_flat)
    );
endmodule

`default_nettype wire
