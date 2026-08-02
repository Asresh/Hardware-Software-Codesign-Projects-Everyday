// ============================================================================
// risk_tables.v - configuration + mutable state storage for the risk engine.
//
//   * per-symbol config  : price_lo, price_hi, max_qty, max_notional, enabled
//   * per-account config : pos_limit, max_msgs, enabled
//   * mutable state      : net position per (account,symbol), accepted count
//
// Config is written word-at-a-time by the APB register file. The pipeline
// reads every field it needs combinationally (async read) in the evaluate
// cycle, and commits a new position + count on an accepted order the same
// cycle. A small clear FSM zeroes the mutable state on soft reset.
// ============================================================================
`default_nettype none

module risk_tables #(
    parameter integer SYM_N  = 32,
    parameter integer ACCT_N = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- config write (from APB regfile) ----
    input  wire        we_sym,
    input  wire [15:0] sym_wr_idx,
    input  wire [2:0]  sym_wr_word,
    input  wire        we_acct,
    input  wire [15:0] acct_wr_idx,
    input  wire [1:0]  acct_wr_word,
    input  wire [31:0] cfg_wdata,

    // ---- soft-reset clear of mutable state ----
    input  wire        clr,
    output reg         clr_busy,

    // ---- pipeline async read ----
    input  wire [15:0] rd_sym,
    input  wire [15:0] rd_acct,
    output wire [31:0] price_lo,
    output wire [31:0] price_hi,
    output wire [31:0] max_qty,
    output wire [63:0] max_not,
    output wire        sym_en,
    output wire [31:0] pos_limit,
    output wire [31:0] max_msgs,
    output wire        acct_en,
    output wire signed [31:0] pos_rd,
    output wire [31:0] cnt_rd,

    // ---- pipeline commit write ----
    input  wire        pos_we,
    input  wire [15:0] pos_wr_sym,
    input  wire [15:0] pos_wr_acct,
    input  wire signed [31:0] pos_wr_data,
    input  wire        cnt_we,
    input  wire [15:0] cnt_wr_acct,
    input  wire [31:0] cnt_wr_data
);
    localparam integer SYMW  = (SYM_N  <= 1) ? 1 : $clog2(SYM_N);
    localparam integer ACCTW = (ACCT_N <= 1) ? 1 : $clog2(ACCT_N);
    localparam integer POS_N = SYM_N * ACCT_N;
    localparam integer POSW  = (POS_N <= 1) ? 1 : $clog2(POS_N);

    // ---- per-symbol config (unpacked fields) ----
    reg [31:0] sym_lo   [0:SYM_N-1];
    reg [31:0] sym_hi   [0:SYM_N-1];
    reg [31:0] sym_mq   [0:SYM_N-1];
    reg [31:0] sym_notl [0:SYM_N-1];
    reg [31:0] sym_noth [0:SYM_N-1];
    reg        sym_e    [0:SYM_N-1];

    // ---- per-account config ----
    reg [31:0] act_pl   [0:ACCT_N-1];
    reg [31:0] act_mm   [0:ACCT_N-1];
    reg        act_e    [0:ACCT_N-1];

    // ---- mutable state ----
    reg [31:0] pos_ram  [0:POS_N-1];
    reg [31:0] cnt_ram  [0:ACCT_N-1];

    // ---- config write ----
    always @(posedge clk) begin
        if (we_sym && sym_wr_idx < SYM_N) begin
            case (sym_wr_word)
                3'd0: sym_lo  [sym_wr_idx[SYMW-1:0]] <= cfg_wdata;
                3'd1: sym_hi  [sym_wr_idx[SYMW-1:0]] <= cfg_wdata;
                3'd2: sym_mq  [sym_wr_idx[SYMW-1:0]] <= cfg_wdata;
                3'd3: sym_notl[sym_wr_idx[SYMW-1:0]] <= cfg_wdata;
                3'd4: sym_noth[sym_wr_idx[SYMW-1:0]] <= cfg_wdata;
                3'd5: sym_e   [sym_wr_idx[SYMW-1:0]] <= cfg_wdata[0];
                default: ;
            endcase
        end
        if (we_acct && acct_wr_idx < ACCT_N) begin
            case (acct_wr_word)
                2'd0: act_pl[acct_wr_idx[ACCTW-1:0]] <= cfg_wdata;
                2'd1: act_mm[acct_wr_idx[ACCTW-1:0]] <= cfg_wdata;
                2'd2: act_e [acct_wr_idx[ACCTW-1:0]] <= cfg_wdata[0];
                default: ;
            endcase
        end
    end

    // ---- clear FSM: zero position + count on soft reset ----
    reg [POSW:0] clr_addr;
    always @(posedge clk) begin
        if (!rst_n) begin
            clr_busy <= 1'b0;
            clr_addr <= 0;
        end else if (clr && !clr_busy) begin
            clr_busy <= 1'b1;
            clr_addr <= 0;
        end else if (clr_busy) begin
            pos_ram[clr_addr[POSW-1:0]] <= 32'd0;
            if (clr_addr < ACCT_N) cnt_ram[clr_addr[ACCTW-1:0]] <= 32'd0;
            if (clr_addr == POS_N-1) begin
                clr_busy <= 1'b0;
            end else begin
                clr_addr <= clr_addr + 1'b1;
            end
        end
    end

    // ---- pipeline commit write (mutable state) ----
    wire [ACCTW-1:0] pw_acct = pos_wr_acct[ACCTW-1:0];
    wire [SYMW-1:0]  pw_sym  = pos_wr_sym[SYMW-1:0];
    wire [POSW-1:0]  pw_key  = pw_acct * SYM_N + pw_sym;
    always @(posedge clk) begin
        if (pos_we && !clr_busy) pos_ram[pw_key]                <= pos_wr_data;
        if (cnt_we && !clr_busy) cnt_ram[cnt_wr_acct[ACCTW-1:0]] <= cnt_wr_data;
    end

    // ---- async read (clamped index; out-of-range handled by REJ_RANGE) ----
    wire [SYMW-1:0]  rsym  = (rd_sym  < SYM_N)  ? rd_sym [SYMW-1:0]  : {SYMW{1'b0}};
    wire [ACCTW-1:0] racct = (rd_acct < ACCT_N) ? rd_acct[ACCTW-1:0] : {ACCTW{1'b0}};
    wire [POSW-1:0]  rkey  = racct * SYM_N + rsym;

    assign price_lo  = sym_lo [rsym];
    assign price_hi  = sym_hi [rsym];
    assign max_qty   = sym_mq [rsym];
    assign max_not   = {sym_noth[rsym], sym_notl[rsym]};
    assign sym_en    = sym_e  [rsym];
    assign pos_limit = act_pl [racct];
    assign max_msgs  = act_mm [racct];
    assign acct_en   = act_e  [racct];
    assign pos_rd    = pos_ram[rkey];
    assign cnt_rd    = cnt_ram[racct];
endmodule

`default_nettype wire
