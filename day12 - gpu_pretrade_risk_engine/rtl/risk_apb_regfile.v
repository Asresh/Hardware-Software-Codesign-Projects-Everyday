// ============================================================================
// risk_apb_regfile.v - APB3 control/status register file for the risk engine.
//
// The control plane: it holds the global CTRL bits (kill switch, engine enable,
// interrupt enable, soft reset), decodes symbol/account config-table writes and
// forwards them to risk_tables, tallies the aggregate statistics (total /
// accepted / rejected and a per-reason histogram) from the pipeline retire
// event, and raises a sticky violation interrupt that firmware clears W1C.
// ============================================================================
`default_nettype none

module risk_apb_regfile #(
    parameter integer SYM_N  = 32,
    parameter integer ACCT_N = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- APB3 slave ----
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [11:0] paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // ---- global control ----
    output reg         kill_switch,
    output reg         engine_enable,
    output reg         irq_enable,
    output reg         soft_reset,     // 1-cycle pulse
    input  wire        clr_busy,

    // ---- config-table write forwarding ----
    output wire        we_sym,
    output wire [15:0] sym_wr_idx,
    output wire [2:0]  sym_wr_word,
    output wire        we_acct,
    output wire [15:0] acct_wr_idx,
    output wire [1:0]  acct_wr_word,
    output wire [31:0] cfg_wdata,

    // ---- decision retire event ----
    input  wire        ev_valid,
    input  wire        ev_accept,
    input  wire [3:0]  ev_reason,
    input  wire [23:0] ev_oid,

    // ---- interrupt ----
    output wire        irq
);
    localparam [31:0] RISK_MAGIC = 32'h15C30512;

    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    wire acc_wr = psel & penable &  pwrite;   // write access phase
    wire acc_rd = psel & penable & ~pwrite;   // read  access phase

    // ---- config-table write decode ----
    localparam [11:0] SYM_BASE  = 12'h400;
    localparam [11:0] ACCT_BASE = 12'h800;
    wire is_sym  = acc_wr && (paddr >= SYM_BASE)  &&
                            (paddr <  SYM_BASE  + SYM_N *12'h20);
    wire is_acct = acc_wr && (paddr >= ACCT_BASE) &&
                            (paddr <  ACCT_BASE + ACCT_N*12'h10);
    assign we_sym       = is_sym;
    assign sym_wr_idx   = (paddr - SYM_BASE) >> 5;
    assign sym_wr_word  = paddr[4:2];
    assign we_acct      = is_acct;
    assign acct_wr_idx  = (paddr - ACCT_BASE) >> 4;
    assign acct_wr_word = paddr[3:2];
    assign cfg_wdata    = pwdata;

    // ---- statistics ----
    reg [31:0] r_total, r_accept, r_reject;
    reg [31:0] r_rej [1:8];
    reg [31:0] r_last;
    reg        irq_pending;

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            kill_switch   <= 1'b0;
            engine_enable <= 1'b0;
            irq_enable    <= 1'b0;
            soft_reset    <= 1'b0;
            r_total <= 0; r_accept <= 0; r_reject <= 0; r_last <= 0;
            irq_pending <= 1'b0;
            for (i = 1; i <= 8; i = i + 1) r_rej[i] <= 0;
        end else begin
            soft_reset <= 1'b0;   // default: pulse low

            // ---- control-plane writes ----
            if (acc_wr) begin
                case (paddr)
                    12'h000: begin
                        kill_switch   <= pwdata[0];
                        engine_enable <= pwdata[1];
                        irq_enable    <= pwdata[2];
                        if (pwdata[3]) soft_reset <= 1'b1;
                    end
                    12'h008: if (pwdata[0]) irq_pending <= 1'b0;   // IRQ_ACK W1C
                    default: ;
                endcase
            end

            // ---- soft reset clears the statistics ----
            if (soft_reset) begin
                r_total <= 0; r_accept <= 0; r_reject <= 0; r_last <= 0;
                for (i = 1; i <= 8; i = i + 1) r_rej[i] <= 0;
            end else if (ev_valid) begin
                // ---- retire-event accounting ----
                r_total <= r_total + 1'b1;
                if (ev_accept) begin
                    r_accept <= r_accept + 1'b1;
                end else begin
                    r_reject <= r_reject + 1'b1;
                    if (ev_reason >= 4'd1 && ev_reason <= 4'd8)
                        r_rej[ev_reason] <= r_rej[ev_reason] + 1'b1;
                    r_last <= {ev_oid, 4'b0, ev_reason};
                    if (irq_enable) irq_pending <= 1'b1;
                end
            end
        end
    end

    assign irq = irq_pending;

    // ---- read mux ----
    always @(*) begin
        prdata = 32'h0;
        if (acc_rd) begin
            case (paddr)
                12'h000: prdata = {28'b0, 1'b0, irq_enable, engine_enable, kill_switch};
                12'h004: prdata = {29'b0, clr_busy, kill_switch, irq_pending};
                12'h00C: prdata = r_total;
                12'h010: prdata = r_accept;
                12'h014: prdata = r_reject;
                12'h018: prdata = r_last;
                12'h01C: prdata = r_rej[1];
                12'h020: prdata = r_rej[2];
                12'h024: prdata = r_rej[3];
                12'h028: prdata = r_rej[4];
                12'h02C: prdata = r_rej[5];
                12'h030: prdata = r_rej[6];
                12'h034: prdata = r_rej[7];
                12'h038: prdata = r_rej[8];
                12'h0FC: prdata = RISK_MAGIC;
                default: prdata = 32'h0;
            endcase
        end
    end
endmodule

`default_nettype wire
