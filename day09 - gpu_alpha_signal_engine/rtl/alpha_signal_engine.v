// ============================================================================
// alpha_signal_engine.v - GPU/FPGA-style real-time alpha-signal accelerator.
//
// Ingests market ticks over AXI4-Stream, maintains per-symbol streaming state
// (fast/slow EWMA, rolling variance, tick count) in an on-chip symbol RAM, and
// for every tick emits an 8-word signal record over an AXI4-Stream master:
// {symbol, price, ewma_fast, ewma_slow, std, z-score, momentum, flags}.  An
// AXI4-Lite register file supplies the decay weights / alert threshold and
// exposes counters; an interrupt fires on threshold-crossing alerts.
//
// Datapath:
//   * single-cycle read-modify-write on the symbol RAM (as_stat_update) so
//     back-to-back ticks on the same symbol stream at one tick/clock with no
//     stale-state hazard;
//   * a deep feed-forward tail - pipelined integer sqrt (std = sqrt(var)) then
//     a pipelined divider (z = deviation / std) - giving deterministic latency
//     at a sustained one tick/clock.
//   * a single global clock-enable stalls the whole pipeline on egress
//     backpressure (fixed-latency feed-forward, so freezing is correct).
// ============================================================================
`default_nettype none

module alpha_signal_engine #(
    parameter integer N_SYM        = 64,
    parameter integer SYMW         = 6,
    parameter integer FRAC         = 16,
    parameter integer EWW          = 32,
    parameter integer VARW         = 48,
    parameter integer ISQRT_STAGES = 32,
    parameter integer DIV_WN       = 48
)(
    input  wire         clk,
    input  wire         rst_n,

    // AXI4-Stream tick ingress: TDATA = {sym[63:32], price[31:0]}
    input  wire         s_tvalid,
    output wire         s_tready,
    input  wire [63:0]  s_tdata,
    input  wire         s_tlast,

    // AXI4-Stream signal egress: TDATA = 8x32-bit record
    output reg          m_tvalid,
    input  wire         m_tready,
    output reg  [255:0] m_tdata,
    output reg          m_tlast,

    // AXI4-Lite control/status
    input  wire [7:0]   awaddr,
    input  wire         awvalid,
    output wire         awready,
    input  wire [31:0]  wdata,
    input  wire [3:0]   wstrb,
    input  wire         wvalid,
    output wire         wready,
    output wire [1:0]   bresp,
    output wire         bvalid,
    input  wire         bready,
    input  wire [7:0]   araddr,
    input  wire         arvalid,
    output wire         arready,
    output wire [31:0]  rdata,
    output wire [1:0]   rresp,
    output wire         rvalid,
    input  wire         rready,

    output wire         irq
);
    localparam integer STW    = EWW + EWW + VARW + 32;   // symbol-state word
    localparam integer META_W = 257 + SYMW;
    localparam integer PAY2_W = META_W + 32;

    // ---- config / status via register file ----
    wire        enable, irq_enable, soft_reset, irq_ack;
    wire [31:0] alpha, beta, gamma, zthresh, warmup;
    reg  [31:0] tick_cnt, rec_cnt, alert_cnt;
    reg         irq_reg;
    wire        busy;

    as_regfile u_reg (
        .clk(clk), .rst_n(rst_n),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .enable(enable), .irq_enable(irq_enable),
        .alpha(alpha), .beta(beta), .gamma(gamma),
        .zthresh(zthresh), .warmup(warmup),
        .soft_reset(soft_reset), .irq_ack(irq_ack),
        .busy(busy), .irq(irq_reg),
        .tick_cnt(tick_cnt), .rec_cnt(rec_cnt), .alert_cnt(alert_cnt)
    );
    assign irq = irq_reg;

    // ---- symbol state RAM ----
    reg [STW-1:0] state_mem [0:N_SYM-1];

    // ---- clear FSM: wipe all symbol counts on reset or soft_reset ----
    reg              clearing;
    reg [SYMW:0]     clr_addr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clearing <= 1'b1; clr_addr <= {(SYMW+1){1'b0}};
        end else if (soft_reset) begin
            clearing <= 1'b1; clr_addr <= {(SYMW+1){1'b0}};
        end else if (clearing) begin
            state_mem[clr_addr[SYMW-1:0]] <= {STW{1'b0}};
            if (clr_addr == N_SYM-1) clearing <= 1'b0;
            clr_addr <= clr_addr + 1'b1;
        end
    end

    // ---- pipeline clock-enable: stall only when egress holds a blocked beat --
    wire en = ~(m_tvalid & ~m_tready);

    // ---- ingress accept ----
    wire            can_accept = enable & ~clearing & en;
    assign s_tready = can_accept;
    wire            accept = s_tvalid & s_tready;
    wire [SYMW-1:0] cur_sym   = s_tdata[32 +: SYMW];
    wire signed [31:0] cur_price = s_tdata[31:0];
    wire            cur_last  = s_tlast;

    // ---- symbol RAM read (async) ----
    wire [STW-1:0]        rd = state_mem[cur_sym];
    wire signed [EWW-1:0] ef_in  = rd[0        +: EWW];
    wire signed [EWW-1:0] es_in  = rd[EWW      +: EWW];
    wire        [VARW-1:0] var_in = rd[2*EWW   +: VARW];
    wire        [31:0]    cnt_in  = rd[2*EWW+VARW +: 32];

    // ---- combinational state update (single-cycle RMW) ----
    wire signed [EWW-1:0] ef_out, es_out;
    wire        [VARW-1:0] var_out;
    wire        [31:0]    cnt_out;
    wire signed [31:0]    dev_out, mom_out;

    as_stat_update #(.FRAC(FRAC), .EWW(EWW), .VARW(VARW)) u_upd (
        .price(cur_price),
        .ef_in(ef_in), .es_in(es_in), .var_in(var_in), .cnt_in(cnt_in),
        .alpha(alpha), .beta(beta), .gamma(gamma),
        .ef_out(ef_out), .es_out(es_out), .var_out(var_out), .cnt_out(cnt_out),
        .dev_out(dev_out), .mom_out(mom_out)
    );

    // commit new state on accept
    always @(posedge clk) begin
        if (en & accept & ~clearing)
            state_mem[cur_sym] <= {cnt_out, var_out, es_out, ef_out};
    end

    // ---- launch metadata into the sqrt/divide tail ----
    wire [META_W-1:0] meta_in =
        { cur_last, cur_sym, warmup, zthresh, cnt_out, dev_out, mom_out,
          es_out, ef_out, cur_price };
    wire [63:0] isqrt_x = { var_out, {FRAC{1'b0}} };   // var << FRAC (Q16.16)

    // ---- pipelined integer sqrt: std = floor(sqrt(var<<FRAC)) ----
    wire              sq_valid;
    wire [31:0]       sq_std;
    wire [META_W-1:0] sq_meta;
    as_isqrt #(.STAGES(ISQRT_STAGES), .PAYW(META_W)) u_isqrt (
        .clk(clk), .en(en),
        .in_valid(accept), .in_x(isqrt_x), .in_pay(meta_in),
        .out_valid(sq_valid), .out_root(sq_std), .out_pay(sq_meta)
    );

    // ---- prepare divide: num = |dev|<<FRAC, den = std ----
    wire signed [31:0] sq_dev = sq_meta[128 +: 32];
    wire        [31:0] sq_absdev = sq_dev[31] ? (~sq_dev + 1'b1) : sq_dev;
    wire [DIV_WN-1:0]  div_num = { sq_absdev, {FRAC{1'b0}} };
    wire [PAY2_W-1:0]  div_pay_in = { sq_meta, sq_std };

    wire              dv_valid;
    wire [DIV_WN-1:0] dv_quot;
    wire [PAY2_W-1:0] dv_pay;
    as_divide #(.WN(DIV_WN), .WD(32), .PAYW(PAY2_W)) u_div (
        .clk(clk), .en(en),
        .in_valid(sq_valid), .in_num(div_num), .in_den(sq_std), .in_pay(div_pay_in),
        .out_valid(dv_valid), .out_quot(dv_quot), .out_pay(dv_pay)
    );

    // ---- tail: reconstruct z, flags, assemble record ----
    wire [31:0]       t_std   = dv_pay[0  +: 32];
    wire [META_W-1:0] t_meta  = dv_pay[32 +: META_W];
    wire signed [31:0] t_price = t_meta[0   +: 32];
    wire signed [31:0] t_ef    = t_meta[32  +: 32];
    wire signed [31:0] t_es    = t_meta[64  +: 32];
    wire signed [31:0] t_mom   = t_meta[96  +: 32];
    wire signed [31:0] t_dev   = t_meta[128 +: 32];
    wire        [31:0] t_cnt   = t_meta[160 +: 32];
    wire        [31:0] t_zth   = t_meta[192 +: 32];
    wire        [31:0] t_warm  = t_meta[224 +: 32];
    wire [SYMW-1:0]    t_sym   = t_meta[256 +: SYMW];
    wire               t_last  = t_meta[256 + SYMW];

    // saturating signed z from the unsigned quotient magnitude (matches
    // asig_z_from: guard std==0, truncate toward zero, saturate to int32).
    reg signed [31:0] z_val;
    always @* begin
        if (t_std == 32'd0)
            z_val = 32'sd0;
        else if (t_dev[31])                                   // negative deviation
            z_val = (dv_quot > 48'h8000_0000) ? 32'sh80000000
                                              : $signed(~dv_quot[31:0] + 32'd1);
        else                                                  // non-negative
            z_val = (dv_quot > 48'h7FFF_FFFF) ? 32'sh7FFFFFFF
                                              : $signed(dv_quot[31:0]);
    end

    wire        warm  = (t_cnt >= t_warm);
    wire signed [31:0] zabs = z_val[31] ? (~z_val + 1'b1) : z_val;
    wire        alert = warm & ($signed(zabs) >= $signed(t_zth));
    wire [31:0] t_flags =
        { 26'd0,
          warm,                      // bit5
          (t_mom < 0),               // bit4 F_MOMDN
          (t_mom > 0),               // bit3 F_MOMUP
          (z_val  < 0),              // bit2 F_ZNEG
          (z_val  > 0),              // bit1 F_ZPOS
          alert };                   // bit0 F_ALERT

    wire [255:0] rec =
        { {(32-SYMW){1'b0}}, t_sym,           // w0 symbol
          t_price,                            // w1
          t_ef,                               // w2
          t_es,                               // w3
          t_std,                              // w4
          z_val,                              // w5
          t_mom,                              // w6
          t_flags };                          // w7

    // ---- egress register + counters + interrupt ----
    reg [31:0] inflight;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_tvalid <= 1'b0; m_tdata <= 256'd0; m_tlast <= 1'b0;
            tick_cnt <= 32'd0; rec_cnt <= 32'd0; alert_cnt <= 32'd0;
            irq_reg  <= 1'b0; inflight <= 32'd0;
        end else begin
            if (soft_reset) begin
                tick_cnt <= 32'd0; rec_cnt <= 32'd0; alert_cnt <= 32'd0;
                inflight <= 32'd0; m_tvalid <= 1'b0; irq_reg <= 1'b0;
            end else if (en) begin
                m_tvalid <= dv_valid;
                m_tdata  <= rec;
                m_tlast  <= t_last;
                if (accept) tick_cnt <= tick_cnt + 1'b1;
            end
            // egress beat retired
            if (m_tvalid & m_tready) begin
                rec_cnt <= rec_cnt + 1'b1;
                if (m_tdata[0]) begin           // F_ALERT in w7 bit0
                    alert_cnt <= alert_cnt + 1'b1;
                    if (irq_enable) irq_reg <= 1'b1;
                end
            end
            // in-flight accounting for busy
            case ({ (en & accept & ~clearing), (dv_valid & en) })
                2'b10: inflight <= inflight + 1'b1;
                2'b01: inflight <= inflight - 1'b1;
                default: inflight <= inflight;
            endcase
            if (irq_ack) irq_reg <= 1'b0;
        end
    end

    assign busy = clearing | (inflight != 0) | m_tvalid;
endmodule

`default_nettype wire
