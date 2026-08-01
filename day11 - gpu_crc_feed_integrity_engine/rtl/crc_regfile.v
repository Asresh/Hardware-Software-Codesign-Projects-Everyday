// ============================================================================
// crc_regfile - AXI4-Lite control/status register file + event counters + IRQ
//
//   The control plane the firmware talks to: enable the engine, arm the
//   interrupt, turn sequence checking on/off, and read back per-channel-feed
//   health (packets processed, CRC failures, sequence gaps, malformed frames)
//   plus a snapshot of the last packet. A single sticky IRQ fires on any
//   integrity failure and is cleared by writing IRQ_ACK. All state updates on
//   the packet-done event bus, one packet per strobe.
//
//   Register map (32-bit, byte address):
//     0x00 CTRL      RW  [0]EN [1]IRQ_EN [2]SEQ_CHK [3]SOFT_RST(self-clear)
//     0x04 STATUS    RO  [0]BUSY [1]IRQ [2]crc_ok [3]seq_ok [4]frame_err [5]first
//     0x08 PKT_COUNT       RO   packets completed
//     0x0C ERR_COUNT       RO   packets with any integrity failure
//     0x10 CRC_ERR_COUNT   RO   CRC mismatches
//     0x14 GAP_COUNT       RO   sequence gaps
//     0x18 FRAME_ERR_COUNT RO   malformed frames
//     0x1C BYTE_COUNT      RO   total bytes CRC'd (low 32)
//     0x20 LAST_CHANNEL    RO
//     0x24 LAST_SEQ        RO
//     0x28 LAST_CRC        RO   computed, finalised
//     0x2C LAST_EXP_CRC    RO   trailer value on the wire
//     0x30 LAST_EXP_SEQ    RO   expected sequence number
//     0x34 IRQ_ACK         W1C  write bit0=1 to clear IRQ
//     0x38 SCRATCH         RW   bring-up sanity register
//     0x3C VERSION         RO   {8'hFE, 8'hED, 16'd0011}
// ============================================================================
`default_nettype none

module crc_regfile (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite slave
    input  wire [7:0]  awaddr,
    input  wire        awvalid,
    output reg         awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wvalid,
    output reg         wready,
    output reg  [1:0]  bresp,
    output reg         bvalid,
    input  wire        bready,
    input  wire [7:0]  araddr,
    input  wire        arvalid,
    output reg         arready,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp,
    output reg         rvalid,
    input  wire        rready,

    // control outputs
    output wire        en,
    output wire        irq_en,
    output wire        seq_check_en,
    output reg         soft_rst,     // one-cycle pulse
    output wire        irq,

    // packet-done event bus (one-cycle strobe)
    input  wire        ev_valid,
    input  wire [15:0] ev_channel,
    input  wire [31:0] ev_seq,
    input  wire [31:0] ev_crc,
    input  wire [31:0] ev_exp_crc,
    input  wire [31:0] ev_exp_seq,
    input  wire [15:0] ev_bytes,     // bytes CRC'd for this packet
    input  wire        ev_crc_ok,
    input  wire        ev_seq_ok,
    input  wire        ev_seq_first,
    input  wire        ev_frame_err
);
    reg [2:0]  ctrl;          // [0]EN [1]IRQ_EN [2]SEQ_CHK
    reg [31:0] scratch;
    reg [31:0] pkt_count, err_count, crc_err_count, gap_count, frame_err_count;
    reg [31:0] byte_count;
    reg [15:0] last_channel;
    reg [31:0] last_seq, last_crc, last_exp_crc, last_exp_seq;
    reg        last_crc_ok, last_seq_ok, last_frame_err, last_first;
    reg        irq_sticky;

    assign en           = ctrl[0];
    assign irq_en       = ctrl[1];
    assign seq_check_en = ctrl[2];
    assign irq          = irq_sticky;

    wire crc_bad  = ev_valid & ~ev_frame_err & ~ev_crc_ok;
    wire gap_bad  = ev_valid & ~ev_frame_err & ~ev_seq_ok;
    wire fr_bad   = ev_valid &  ev_frame_err;
    wire any_bad  = crc_bad | gap_bad | fr_bad;

    // ---- write channel ----
    wire wr_fire = awvalid & wvalid & ~bvalid;
    always @(posedge clk) begin
        if (!rst_n) begin
            awready  <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; bresp <= 2'b00;
            ctrl     <= 3'b000;
            scratch  <= 32'h0;
            soft_rst <= 1'b0;
        end else begin
            soft_rst <= 1'b0;
            awready  <= 1'b0; wready <= 1'b0;
            if (wr_fire) begin
                awready <= 1'b1; wready <= 1'b1; bvalid <= 1'b1; bresp <= 2'b00;
                case (awaddr[7:2])
                    6'h00: begin
                        if (wstrb[0]) ctrl <= wdata[2:0];
                        soft_rst <= wdata[3];    // self-clearing pulse
                    end
                    6'h0D: begin /* 0x34 IRQ_ACK handled below (clears sticky) */ end
                    6'h0E: if (wstrb[0]) scratch <= wdata;   // 0x38 SCRATCH
                    default: ;
                endcase
            end else if (bvalid && bready) begin
                bvalid <= 1'b0;
            end
        end
    end

    // ---- read channel ----
    always @(posedge clk) begin
        if (!rst_n) begin
            arready <= 1'b0; rvalid <= 1'b0; rresp <= 2'b00; rdata <= 32'h0;
        end else begin
            arready <= 1'b0;
            if (arvalid & ~rvalid) begin
                arready <= 1'b1;
                rvalid  <= 1'b1;
                rresp   <= 2'b00;
                case (araddr[7:2])
                    6'h00: rdata <= {29'b0, ctrl};
                    6'h01: rdata <= {26'b0, last_first, last_frame_err,
                                     last_seq_ok, last_crc_ok, irq_sticky, en};
                    6'h02: rdata <= pkt_count;
                    6'h03: rdata <= err_count;
                    6'h04: rdata <= crc_err_count;
                    6'h05: rdata <= gap_count;
                    6'h06: rdata <= frame_err_count;
                    6'h07: rdata <= byte_count;
                    6'h08: rdata <= {16'b0, last_channel};
                    6'h09: rdata <= last_seq;
                    6'h0A: rdata <= last_crc;
                    6'h0B: rdata <= last_exp_crc;
                    6'h0C: rdata <= last_exp_seq;
                    6'h0D: rdata <= {31'b0, irq_sticky};
                    6'h0E: rdata <= scratch;
                    6'h0F: rdata <= {8'hFE, 8'hED, 16'd11};
                    default: rdata <= 32'h0;
                endcase
            end else if (rvalid & rready) begin
                rvalid <= 1'b0;
            end
        end
    end

    // ---- counters, snapshot, IRQ ----
    wire irq_ack = wr_fire & (awaddr[7:2] == 6'h0D) & wdata[0];
    always @(posedge clk) begin
        if (!rst_n) begin
            pkt_count <= 0; err_count <= 0; crc_err_count <= 0;
            gap_count <= 0; frame_err_count <= 0; byte_count <= 0;
            last_channel <= 0; last_seq <= 0; last_crc <= 0;
            last_exp_crc <= 0; last_exp_seq <= 0;
            last_crc_ok <= 0; last_seq_ok <= 0; last_frame_err <= 0; last_first <= 0;
            irq_sticky <= 1'b0;
        end else begin
            if (soft_rst) begin
                pkt_count <= 0; err_count <= 0; crc_err_count <= 0;
                gap_count <= 0; frame_err_count <= 0; byte_count <= 0;
                irq_sticky <= 1'b0;
            end
            if (ev_valid) begin
                pkt_count       <= pkt_count + 1;
                err_count       <= err_count + (any_bad ? 32'd1 : 32'd0);
                crc_err_count   <= crc_err_count + (crc_bad ? 32'd1 : 32'd0);
                gap_count       <= gap_count + (gap_bad ? 32'd1 : 32'd0);
                frame_err_count <= frame_err_count + (fr_bad ? 32'd1 : 32'd0);
                byte_count      <= byte_count + {16'b0, ev_bytes};
                last_channel    <= ev_channel;
                last_seq        <= ev_seq;
                last_crc        <= ev_crc;
                last_exp_crc    <= ev_exp_crc;
                last_exp_seq    <= ev_exp_seq;
                last_crc_ok     <= ev_crc_ok & ~ev_frame_err;
                last_seq_ok     <= ev_seq_ok & ~ev_frame_err;
                last_frame_err  <= ev_frame_err;
                last_first      <= ev_seq_first;
                if (irq_en & any_bad) irq_sticky <= 1'b1;
            end
            if (irq_ack)  irq_sticky <= 1'b0;   // W1C wins over concurrent set
        end
    end
endmodule

`default_nettype wire
