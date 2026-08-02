// ============================================================================
// moe_axi_regfile - AXI4-Lite control/status register file + IRQ.
//
//   The control plane the firmware talks to: enable the engine, program the
//   per-expert capacity, arm the over-capacity interrupt, and read back the
//   routing statistics and per-expert load counters.  A single sticky IRQ
//   fires whenever a token is dropped over capacity and is cleared W1C by
//   writing STATUS bit0.
//
//   Register map (32-bit byte address):
//     0x00 CTRL      RW  [0]EN [1]SOFT_RST(self-clear) [2]IRQ_EN
//     0x04 STATUS    RO/W1C [0]OVF_IRQ (sticky; write 1 to clear)
//     0x08 CAP       RW  per-expert capacity (tokens)
//     0x0C TOKENS    RO  total tokens processed
//     0x10 OVERFLOWS RO  total dropped (over-capacity) slots
//     0x14 ROUTED    RO  total accepted routed slots
//     0x18 PARAMS    RO  [7:0]E [15:8]K [23:16]LOGIT_W
//     0x1C SCRATCH   RW  bring-up sanity
//     0x20 VERSION   RO  {8'hFE,8'hED,16'd13}
//     0x40+4i        RO  per-expert accepted-token load counter (i=0..E-1)
// ============================================================================
`default_nettype none

module moe_axi_regfile #(
    parameter integer E       = 8,
    parameter integer K       = 2,
    parameter integer LOGIT_W = 16
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite slave
    input  wire [11:0] awaddr,
    input  wire        awvalid,
    output reg         awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wvalid,
    output reg         wready,
    output reg  [1:0]  bresp,
    output reg         bvalid,
    input  wire        bready,
    input  wire [11:0] araddr,
    input  wire        arvalid,
    output reg         arready,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp,
    output reg         rvalid,
    input  wire        rready,

    // control outputs
    output wire        en,
    output wire        irq_en,
    output reg         soft_rst,      // one-cycle pulse (also clears counters)
    output wire [31:0] cap,
    output wire        irq,

    // statistics inputs (from moe_capacity)
    input  wire        ovf_pulse,     // token dropped this cycle
    input  wire [31:0] tokens,
    input  wire [31:0] overflow_tot,
    input  wire [31:0] routed_tot,
    input  wire [E*32-1:0] load_flat
);
    reg [2:0]  ctrl;      // [0]EN [1]SOFT_RST [2]IRQ_EN
    reg [31:0] cap_r;
    reg [31:0] scratch;
    reg        irq_sticky;

    assign en     = ctrl[0];
    assign irq_en = ctrl[2];
    assign cap    = cap_r;
    assign irq    = irq_sticky;

    // ---- write channel ----
    wire wr_fire = awvalid & wvalid & ~bvalid;
    wire irq_clr = wr_fire & (awaddr[11:2] == 10'h001) & wdata[0];  // STATUS W1C

    always @(posedge clk) begin
        if (!rst_n) begin
            awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; bresp <= 2'b00;
            ctrl <= 3'b000; cap_r <= 32'd0; scratch <= 32'd0; soft_rst <= 1'b0;
        end else begin
            soft_rst <= 1'b0;
            awready  <= 1'b0; wready <= 1'b0;
            if (wr_fire) begin
                awready <= 1'b1; wready <= 1'b1; bvalid <= 1'b1; bresp <= 2'b00;
                case (awaddr[11:2])
                    10'h000: begin
                        if (wstrb[0]) ctrl <= {wdata[2], 1'b0, wdata[0]};
                        soft_rst <= wdata[1];        // self-clearing pulse
                    end
                    10'h002: if (wstrb[0]) cap_r  <= wdata;
                    10'h007: if (wstrb[0]) scratch <= wdata;
                    default: ;
                endcase
            end else if (bvalid && bready) begin
                bvalid <= 1'b0;
            end
        end
    end

    // ---- read channel ----
    wire [9:0]  rword = araddr[11:2];
    wire        is_load = (rword >= 10'h010) && (rword < (10'h010 + E));
    // resolve the per-expert load counter by window offset
    reg  [31:0] load_sel;
    integer j;
    always @* begin
        load_sel = 32'd0;
        for (j = 0; j < E; j = j + 1)
            if (rword == (10'h010 + j)) load_sel = load_flat[j*32 +: 32];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            arready <= 1'b0; rvalid <= 1'b0; rresp <= 2'b00; rdata <= 32'd0;
        end else begin
            arready <= 1'b0;
            if (arvalid & ~rvalid) begin
                arready <= 1'b1; rvalid <= 1'b1; rresp <= 2'b00;
                if (is_load) begin
                    rdata <= load_sel;
                end else begin
                    case (rword)
                        10'h000: rdata <= {29'b0, ctrl};
                        10'h001: rdata <= {31'b0, irq_sticky};
                        10'h002: rdata <= cap_r;
                        10'h003: rdata <= tokens;
                        10'h004: rdata <= overflow_tot;
                        10'h005: rdata <= routed_tot;
                        10'h006: rdata <= {8'b0, LOGIT_W[7:0], K[7:0], E[7:0]};
                        10'h007: rdata <= scratch;
                        10'h008: rdata <= {8'hFE, 8'hED, 16'd13};
                        default: rdata <= 32'd0;
                    endcase
                end
            end else if (rvalid & rready) begin
                rvalid <= 1'b0;
            end
        end
    end

    // ---- sticky over-capacity IRQ ----
    always @(posedge clk) begin
        if (!rst_n)            irq_sticky <= 1'b0;
        else begin
            if (soft_rst)      irq_sticky <= 1'b0;
            if (irq_en & ovf_pulse) irq_sticky <= 1'b1;
            if (irq_clr)       irq_sticky <= 1'b0;   // W1C wins
        end
    end
endmodule

`default_nettype wire
