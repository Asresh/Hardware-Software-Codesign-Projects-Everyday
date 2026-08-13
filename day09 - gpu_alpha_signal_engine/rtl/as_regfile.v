// ============================================================================
// as_regfile.v - AXI4-Lite control/status register file for the engine.
//
// A minimal single-outstanding AXI4-Lite slave.  Holds the streaming config
// (decay weights, alert threshold, warm-up) that the datapath consumes, exposes
// read-only counters, and emits a soft-reset pulse and an interrupt-acknowledge
// pulse.  Register map (byte addresses, 32-bit words):
//
//   0x00 CTRL      [0] enable  [1] soft_reset (pulse)  [2] irq_enable
//   0x04 ALPHA     Q0.16 fast-EWMA weight
//   0x08 BETA      Q0.16 slow-EWMA weight
//   0x0C GAMMA     Q0.16 variance weight
//   0x10 ZTHRESH   Q16.16 |z| alert threshold
//   0x14 WARMUP    ticks before signals arm
//   0x18 STATUS    RO [0] busy (pipeline non-empty) [1] irq
//   0x1C TICKCNT   RO accepted ticks
//   0x20 RECCNT    RO emitted records
//   0x24 ALERTCNT  RO alerts raised
//   0x28 IRQ_ACK   W  any write clears the interrupt
// ============================================================================
`default_nettype none

module as_regfile (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite slave
    input  wire [7:0]  awaddr,
    input  wire        awvalid,
    output wire        awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wvalid,
    output wire        wready,
    output reg  [1:0]  bresp,
    output reg         bvalid,
    input  wire        bready,
    input  wire [7:0]  araddr,
    input  wire        arvalid,
    output wire        arready,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp,
    output reg         rvalid,
    input  wire        rready,

    // config outputs to the datapath
    output reg         enable,
    output reg         irq_enable,
    output reg  [31:0] alpha,
    output reg  [31:0] beta,
    output reg  [31:0] gamma,
    output reg  [31:0] zthresh,
    output reg  [31:0] warmup,
    output reg         soft_reset,   // 1-cycle pulse
    output reg         irq_ack,      // 1-cycle pulse

    // status inputs
    input  wire        busy,
    input  wire        irq,
    input  wire [31:0] tick_cnt,
    input  wire [31:0] rec_cnt,
    input  wire [31:0] alert_cnt
);
    // ---- write channel (single outstanding) ----
    wire do_wr = awvalid & wvalid & ~bvalid;
    assign awready = do_wr;
    assign wready  = do_wr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable <= 1'b0; irq_enable <= 1'b0;
            alpha <= 32'd0; beta <= 32'd0; gamma <= 32'd0;
            zthresh <= 32'd0; warmup <= 32'd0;
            soft_reset <= 1'b0; irq_ack <= 1'b0;
            bvalid <= 1'b0; bresp <= 2'b00;
        end else begin
            soft_reset <= 1'b0;   // default: pulses low
            irq_ack    <= 1'b0;
            if (do_wr) begin
                case (awaddr[7:0])
                    8'h00: begin enable <= wdata[0]; soft_reset <= wdata[1];
                                 irq_enable <= wdata[2]; end
                    8'h04: alpha   <= wdata;
                    8'h08: beta    <= wdata;
                    8'h0C: gamma   <= wdata;
                    8'h10: zthresh <= wdata;
                    8'h14: warmup  <= wdata;
                    8'h28: irq_ack <= 1'b1;    // IRQ_ACK
                    default: ;
                endcase
                bvalid <= 1'b1; bresp <= 2'b00;
            end else if (bvalid & bready) begin
                bvalid <= 1'b0;
            end
        end
    end

    // ---- read channel ----
    assign arready = ~rvalid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rvalid <= 1'b0; rdata <= 32'd0; rresp <= 2'b00;
        end else begin
            if (arvalid & arready) begin
                rvalid <= 1'b1; rresp <= 2'b00;
                case (araddr[7:0])
                    8'h00: rdata <= {29'd0, irq_enable, soft_reset, enable};
                    8'h04: rdata <= alpha;
                    8'h08: rdata <= beta;
                    8'h0C: rdata <= gamma;
                    8'h10: rdata <= zthresh;
                    8'h14: rdata <= warmup;
                    8'h18: rdata <= {30'd0, irq, busy};
                    8'h1C: rdata <= tick_cnt;
                    8'h20: rdata <= rec_cnt;
                    8'h24: rdata <= alert_cnt;
                    default: rdata <= 32'd0;
                endcase
            end else if (rvalid & rready) begin
                rvalid <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
