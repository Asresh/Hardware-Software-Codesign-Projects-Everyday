// ============================================================================
// ob_regfile - 32-bit MMIO control / snapshot register file.
//
// Single-cycle register interface (no wait states). Holds the control bits and
// muxes the read-back of the status word, the message counter and the latched
// best-bid / best-offer snapshot. Side-effect writes (soft reset, irq ack) are
// exported as one-cycle pulses; the datapath in the top level consumes them.
//
//   0x00 CTRL     [0] soft_reset (pulse) [1] irq_enable (level)
//   0x04 STATUS   [0] busy [1] overflow [2] irq_pending [15:8] active_levels
//   0x08 MSGCOUNT messages committed since reset
//   0x0C IRQACK   write 1 -> clear irq_pending + overflow
//   0x10 BID_PX   [PW] valid  [PW-1:0] price
//   0x14 BID_QTY  [QW-1:0] qty
//   0x18 ASK_PX   [PW] valid  [PW-1:0] price
//   0x1C ASK_QTY  [QW-1:0] qty
// ============================================================================
`default_nettype none
module ob_regfile #(
    parameter integer PW = 16,
    parameter integer QW = 24
) (
    input  wire        clk,
    input  wire        rst_n,
    // MMIO
    input  wire [7:0]  reg_addr,
    input  wire        reg_wr,
    input  wire        reg_rd,
    input  wire [31:0] reg_wdata,
    output reg  [31:0] reg_rdata,
    // status inputs
    input  wire        busy,
    input  wire        overflow,
    input  wire        irq_pending,
    input  wire [7:0]  active_count,
    input  wire [31:0] msg_count,
    input  wire        bid_valid,
    input  wire [PW-1:0] bid_price,
    input  wire [QW-1:0] bid_qty,
    input  wire        ask_valid,
    input  wire [PW-1:0] ask_price,
    input  wire [QW-1:0] ask_qty,
    // control outputs
    output reg         irq_en,
    output wire        soft_reset,
    output wire        irq_ack
);
    localparam [7:0] REG_CTRL     = 8'h00;
    localparam [7:0] REG_STATUS   = 8'h04;
    localparam [7:0] REG_MSGCOUNT = 8'h08;
    localparam [7:0] REG_IRQACK   = 8'h0C;
    localparam [7:0] REG_BID_PX   = 8'h10;
    localparam [7:0] REG_BID_QTY  = 8'h14;
    localparam [7:0] REG_ASK_PX   = 8'h18;
    localparam [7:0] REG_ASK_QTY  = 8'h1C;

    wire ctrl_wr = reg_wr & (reg_addr == REG_CTRL);
    assign soft_reset = ctrl_wr & reg_wdata[0];
    assign irq_ack    = reg_wr & (reg_addr == REG_IRQACK) & reg_wdata[0];

    always @(posedge clk) begin
        if (!rst_n)          irq_en <= 1'b0;
        else if (ctrl_wr)    irq_en <= reg_wdata[1];
    end

    // ---- read mux ----
    always @* begin
        reg_rdata = 32'h0;
        case (reg_addr)
            REG_CTRL:     reg_rdata = {30'h0, irq_en, 1'b0};
            REG_STATUS:   reg_rdata = {16'h0, active_count,
                                       1'b0, irq_pending, overflow, busy};
            REG_MSGCOUNT: reg_rdata = msg_count;
            REG_BID_PX:   reg_rdata = {{(32-1-PW){1'b0}}, bid_valid, bid_price};
            REG_BID_QTY:  reg_rdata = {{(32-QW){1'b0}}, bid_qty};
            REG_ASK_PX:   reg_rdata = {{(32-1-PW){1'b0}}, ask_valid, ask_price};
            REG_ASK_QTY:  reg_rdata = {{(32-QW){1'b0}}, ask_qty};
            default:      reg_rdata = 32'h0;
        endcase
    end
    // silence unused
    wire _unused = &{1'b0, reg_rd};
endmodule
`default_nettype wire
