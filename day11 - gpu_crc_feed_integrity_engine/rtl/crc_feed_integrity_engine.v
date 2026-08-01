// ============================================================================
// crc_feed_integrity_engine - line-rate market-data feed integrity accelerator
//
//   Top level. An AXI4-Stream carries feed packets in at one 32-bit beat /
//   clock; the engine CRC-32-checks each packet (Ethernet-FCS / zlib) at four
//   bytes per clock and, per channel, verifies the sequence number is
//   contiguous - the two integrity checks every HFT feed handler runs on the
//   critical path before a message reaches the strategy. A completed packet
//   raises a one-cycle result strobe (sampled by the testbench and mirrored in
//   the CSR snapshot); any CRC failure, sequence gap, or malformed frame sets a
//   sticky interrupt. Firmware drives it over AXI4-Lite.
//
//   Datapath : crc32_unit  (combinational 4-byte GF(2) fold)
//   Framing  : pkt_parser   (header / payload / trailer FSM + byte accounting)
//   Gaps     : seq_tracker  (per-channel sequence RAM)
//   Control  : crc_regfile  (AXI4-Lite CSR + counters + IRQ)
// ============================================================================
`default_nettype none

module crc_feed_integrity_engine #(
    parameter integer CHW = 8            // channel index bits (NCH = 2**CHW)
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Stream packet ingress
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // AXI4-Lite control/status
    input  wire [7:0]  s_axil_awaddr,
    input  wire        s_axil_awvalid,
    output wire        s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output wire        s_axil_wready,
    output wire [1:0]  s_axil_bresp,
    output wire        s_axil_bvalid,
    input  wire        s_axil_bready,
    input  wire [7:0]  s_axil_araddr,
    input  wire        s_axil_arvalid,
    output wire        s_axil_arready,
    output wire [31:0] s_axil_rdata,
    output wire [1:0]  s_axil_rresp,
    output wire        s_axil_rvalid,
    input  wire        s_axil_rready,

    // interrupt
    output wire        irq,

    // per-packet result (debug / verification tap)
    output wire        res_valid,
    output wire [15:0] res_channel,
    output wire [31:0] res_seq,
    output wire [31:0] res_crc,
    output wire [31:0] res_exp_crc,
    output wire [15:0] res_plen,
    output wire        res_crc_ok,
    output wire        res_seq_ok,
    output wire        res_seq_first,
    output wire        res_frame_err
);
    // ---- control plane <-> datapath ----
    wire en, irq_en, seq_check_en, soft_rst;

    // ---- parser results ----
    wire        p_valid;
    wire [15:0] p_channel;
    wire [31:0] p_seq;
    wire [31:0] p_crc;
    wire [31:0] p_exp_crc;
    wire [15:0] p_plen;
    wire        p_crc_ok;
    wire        p_frame_err;

    pkt_parser u_parser (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .s_tdata   (s_axis_tdata),
        .s_tvalid  (s_axis_tvalid),
        .s_tready  (s_axis_tready),
        .s_tlast   (s_axis_tlast),
        .res_valid (p_valid),
        .res_channel(p_channel),
        .res_seq   (p_seq),
        .res_crc   (p_crc),
        .res_exp_crc(p_exp_crc),
        .res_plen  (p_plen),
        .res_crc_ok(p_crc_ok),
        .res_frame_err(p_frame_err)
    );

    // ---- per-channel sequence tracking (combinational, aligned to p_valid) ----
    wire        t_seq_ok, t_seq_first;
    wire [31:0] t_exp_seq;

    seq_tracker #(.CHW(CHW)) u_seq (
        .clk        (clk),
        .rst_n      (rst_n),
        .soft_rst   (soft_rst),
        .check_en   (seq_check_en),
        .pv         (p_valid),
        .channel    (p_channel),
        .seq        (p_seq),
        .frame_err  (p_frame_err),
        .seq_ok     (t_seq_ok),
        .seq_first  (t_seq_first),
        .expected_seq(t_exp_seq)
    );

    // bytes CRC'd this packet: two header words + declared payload length
    wire [15:0] ev_bytes = p_frame_err ? 16'd0 : (16'd8 + p_plen);

    crc_regfile u_regs (
        .clk     (clk),   .rst_n   (rst_n),
        .awaddr  (s_axil_awaddr),  .awvalid (s_axil_awvalid), .awready(s_axil_awready),
        .wdata   (s_axil_wdata),   .wstrb   (s_axil_wstrb),   .wvalid (s_axil_wvalid), .wready(s_axil_wready),
        .bresp   (s_axil_bresp),   .bvalid  (s_axil_bvalid),  .bready (s_axil_bready),
        .araddr  (s_axil_araddr),  .arvalid (s_axil_arvalid), .arready(s_axil_arready),
        .rdata   (s_axil_rdata),   .rresp   (s_axil_rresp),   .rvalid (s_axil_rvalid), .rready(s_axil_rready),
        .en      (en), .irq_en(irq_en), .seq_check_en(seq_check_en),
        .soft_rst(soft_rst), .irq(irq),
        .ev_valid (p_valid),
        .ev_channel(p_channel),
        .ev_seq   (p_seq),
        .ev_crc   (p_crc),
        .ev_exp_crc(p_exp_crc),
        .ev_exp_seq(t_exp_seq),
        .ev_bytes (ev_bytes),
        .ev_crc_ok (p_crc_ok),
        .ev_seq_ok (t_seq_ok),
        .ev_seq_first(t_seq_first),
        .ev_frame_err(p_frame_err)
    );

    // ---- verification tap ----
    assign res_valid     = p_valid;
    assign res_channel   = p_channel;
    assign res_seq       = p_seq;
    assign res_crc       = p_crc;
    assign res_exp_crc   = p_exp_crc;
    assign res_plen      = p_plen;
    assign res_crc_ok    = p_crc_ok & ~p_frame_err;
    assign res_seq_ok    = t_seq_ok & ~p_frame_err;
    assign res_seq_first = t_seq_first;
    assign res_frame_err = p_frame_err;
endmodule

`default_nettype wire
