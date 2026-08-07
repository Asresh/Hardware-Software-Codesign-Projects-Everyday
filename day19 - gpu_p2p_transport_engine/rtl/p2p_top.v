// ============================================================================
// p2p_top - GPU-to-GPU peer transport engine.
//
//   AXI4-Lite slave  : control/status plane and doorbell
//   AXI4-Lite master : one read channel (shared) and one write channel
//   AXI4-Stream      : egress packets out, ingress packets in
//   credit sideband  : returns out, grants in
//
// Reads and writes are on separate AXI channels and are owned by opposite
// directions of the link - the transmitter reads, the receiver writes - so a
// full-duplex transfer moves one word out of memory and one word into memory
// on the same clock. The only shared resource is the read channel, which the
// work-queue fetcher, the transmit payload fetch and the receive accumulate
// path contend for through a round-robin arbiter.
//
// The egress stream and the ingress stream are separate ports: in a node the
// egress of one engine drives the ingress of the peer's engine and the credit
// sideband runs the other way. The testbench closes both loops on a single
// instance with randomised delay, which exercises the transmit path, the wire,
// the receive path and the flow-control loop in one simulation.
//
// A run is over when the ring has been drained, the transmitter is idle, every
// packet that went out has retired at the far end, and no memory transaction
// is still in flight. That last term matters: without it the interrupt could
// fire while the final completion entry is still on the write channel.
// ============================================================================
`timescale 1ns/1ps
`include "p2p_defs.vh"

module p2p_top #(
    parameter MTU_WORDS     = 16,
    parameter NUM_QP        = 4,
    parameter RX_BUFS       = 4,
    parameter MAX_MSG_WORDS = 4096,
    parameter RD_OUTSTAND   = 4,
    parameter WR_OUTSTAND   = 4
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- control plane ------------------------------------------------------
    input  wire [11:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [1:0]  s_bresp,
    output wire        s_bvalid,
    input  wire        s_bready,
    input  wire [11:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rvalid,
    input  wire        s_rready,

    // ---- memory master ------------------------------------------------------
    output wire [31:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output wire        m_rready,

    output wire [31:0] m_awaddr,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,

    // ---- link ---------------------------------------------------------------
    output wire        tx_tvalid,
    output wire [31:0] tx_tdata,
    output wire        tx_tlast,
    output wire        tx_tuser,
    input  wire        tx_tready,

    input  wire        rx_tvalid,
    input  wire [31:0] rx_tdata,
    input  wire        rx_tlast,
    input  wire        rx_tuser,
    output wire        rx_tready,

    // ---- credit sideband ----------------------------------------------------
    output wire        cro_valid,      // credits this receiver returns
    output wire [3:0]  cro_qp,
    input  wire        cro_ready,
    input  wire        cri_valid,      // credits granted to this transmitter
    input  wire [3:0]  cri_qp,

    output wire        irq
);

    // ------------------------------------------------------------ control
    wire [31:0] wq_base, wq_count, cq_base, mem_limit, err_index;
    wire [4:0]  credit_lim;
    wire        inject_skip, start, abort, busy;
    wire [31:0] cycles;
    wire [3:0]  err_code;

    // ------------------------------------------------------------ read path
    wire        rm_req_valid, rm_req_ready, rm_rsp_valid, rm_rsp_err;
    wire [31:0] rm_req_addr, rm_rsp_data;
    wire [3:0]  rd_out;

    wire        a0_v, a0_r, a0_rsp, a1_v, a1_r, a1_rsp, a2_v, a2_r, a2_rsp;
    wire [31:0] a0_a, a1_a, a2_a;

    p2p_rd_arb #(.TAGD(8)) u_arb (
        .clk(clk), .rst_n(rst_n), .flush(start || abort),
        .a0_valid(a0_v), .a0_addr(a0_a), .a0_ready(a0_r), .a0_rsp(a0_rsp),
        .a1_valid(a1_v), .a1_addr(a1_a), .a1_ready(a1_r), .a1_rsp(a1_rsp),
        .a2_valid(a2_v), .a2_addr(a2_a), .a2_ready(a2_r), .a2_rsp(a2_rsp),
        .req_valid(rm_req_valid), .req_addr(rm_req_addr),
        .req_ready(rm_req_ready), .rsp_valid(rm_rsp_valid)
    );

    p2p_axil_rd #(.OUTSTANDING(RD_OUTSTAND)) u_rd (
        .clk(clk), .rst_n(rst_n),
        .req_valid(rm_req_valid), .req_addr(rm_req_addr),
        .req_ready(rm_req_ready),
        .rsp_valid(rm_rsp_valid), .rsp_data(rm_rsp_data), .rsp_err(rm_rsp_err),
        .outstanding(rd_out),
        .m_araddr(m_araddr), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rvalid(m_rvalid),
        .m_rready(m_rready)
    );

    // ----------------------------------------------------------- write path
    wire        wm_req_valid, wm_req_ready, wm_done_valid, wm_done_err;
    wire [31:0] wm_req_addr, wm_req_data;
    wire [3:0]  wr_out;

    p2p_axil_wr #(.OUTSTANDING(WR_OUTSTAND)) u_wr (
        .clk(clk), .rst_n(rst_n),
        .req_valid(wm_req_valid), .req_addr(wm_req_addr),
        .req_data(wm_req_data), .req_ready(wm_req_ready),
        .done_valid(wm_done_valid), .done_err(wm_done_err),
        .outstanding(wr_out),
        .m_awaddr(m_awaddr), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wvalid(m_wvalid),
        .m_wready(m_wready),
        .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready)
    );

    // ------------------------------------------------------- work queue
    wire        wqe_valid, wqe_ready;
    wire [3:0]  wqe_op, wqe_qp;
    wire [31:0] wqe_src, wqe_dst, wqe_len;
    wire [7:0]  wqe_tag;
    wire        fetch_done, err_pulse;
    wire [31:0] st_wqe;

    p2p_wqe_fetch #(.NUM_QP(NUM_QP), .MAX_MSG_WORDS(MAX_MSG_WORDS)) u_wqf (
        .clk(clk), .rst_n(rst_n), .start(start), .abort(abort),
        .wq_base(wq_base), .wq_count(wq_count), .mem_limit(mem_limit),
        .rd_valid(a0_v), .rd_addr(a0_a), .rd_ready(a0_r),
        .rd_rsp(a0_rsp), .rd_data(rm_rsp_data), .rd_err(rm_rsp_err && a0_rsp),
        .wqe_valid(wqe_valid), .wqe_ready(wqe_ready),
        .wqe_op(wqe_op), .wqe_qp(wqe_qp), .wqe_src(wqe_src),
        .wqe_dst(wqe_dst), .wqe_len(wqe_len), .wqe_tag(wqe_tag),
        .fetch_done(fetch_done), .err_pulse(err_pulse),
        .err_code(err_code), .err_index(err_index), .accepted(st_wqe)
    );

    // -------------------------------------------------------- transmitter
    wire        tx_busy, tx_bus_err;
    wire [31:0] st_pkt, st_txw, st_crstall, st_lkstall, tx_memstall;

    p2p_tx #(.MTU_WORDS(MTU_WORDS), .NUM_QP(NUM_QP), .RX_BUFS(RX_BUFS),
             .STAGE_D(8)) u_tx (
        .clk(clk), .rst_n(rst_n), .start(start), .abort(abort),
        .credit_lim(credit_lim), .inject_skip(inject_skip),
        .wqe_valid(wqe_valid), .wqe_ready(wqe_ready),
        .wqe_op(wqe_op), .wqe_qp(wqe_qp), .wqe_src(wqe_src),
        .wqe_dst(wqe_dst), .wqe_len(wqe_len), .wqe_tag(wqe_tag),
        .rd_valid(a1_v), .rd_addr(a1_a), .rd_ready(a1_r),
        .rd_rsp(a1_rsp), .rd_data(rm_rsp_data), .rd_err(rm_rsp_err && a1_rsp),
        .cr_valid(cri_valid), .cr_qp(cri_qp),
        .tx_tvalid(tx_tvalid), .tx_tdata(tx_tdata), .tx_tlast(tx_tlast),
        .tx_tuser(tx_tuser), .tx_tready(tx_tready),
        .tx_busy(tx_busy), .pkt_count(st_pkt), .txw_count(st_txw),
        .cred_stall(st_crstall), .link_stall(st_lkstall),
        .mem_stall(tx_memstall), .bus_err(tx_bus_err)
    );

    // ----------------------------------------------------------- receiver
    wire        rx_busy, rx_bus_err;
    wire [31:0] st_rxw, st_cqe, st_seq, st_frm, rx_retired, rx_memstall;

    p2p_rx #(.MTU_WORDS(MTU_WORDS), .NUM_QP(NUM_QP), .RX_BUFS(RX_BUFS)) u_rx (
        .clk(clk), .rst_n(rst_n), .start(start), .abort(abort),
        .cq_base(cq_base),
        .rx_tvalid(rx_tvalid), .rx_tdata(rx_tdata), .rx_tlast(rx_tlast),
        .rx_tuser(rx_tuser), .rx_tready(rx_tready),
        .rd_valid(a2_v), .rd_addr(a2_a), .rd_ready(a2_r),
        .rd_rsp(a2_rsp), .rd_data(rm_rsp_data), .rd_err(rm_rsp_err && a2_rsp),
        .wr_valid(wm_req_valid), .wr_addr(wm_req_addr), .wr_data(wm_req_data),
        .wr_ready(wm_req_ready), .wr_err(wm_done_err),
        .wr_idle(wr_out == 4'd0),
        .cr_valid(cro_valid), .cr_qp(cro_qp), .cr_ready(cro_ready),
        .rx_busy(rx_busy), .rxw_count(st_rxw), .cqe_count(st_cqe),
        .seqerr_count(st_seq), .frm_count(st_frm),
        .pkts_retired(rx_retired), .mem_stall(rx_memstall),
        .bus_err(rx_bus_err)
    );

    // ------------------------------------------------------ run completion
    reg [31:0] st_err;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      st_err <= 32'd0;
        else if (start)  st_err <= 32'd0;
        else if (abort)  st_err <= 32'd0;
        else if (err_pulse) st_err <= st_err + 32'd1;
    end

    // `fetch_done` is still standing from the previous launch during the cycle
    // the doorbell is written, so completion is not looked at until the fetch
    // engine has had the clock it needs to drop it. Without this a launch that
    // follows another one would retire before it started.
    reg armed;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) armed <= 1'b0;
        else        armed <= busy && !start;
    end

    wire all_done = armed && fetch_done && !tx_busy && !rx_busy && !wqe_valid &&
                    (st_pkt == rx_retired) &&
                    (rd_out == 4'd0) && (wr_out == 4'd0);

    // ------------------------------------------------------------- regfile
    p2p_regfile #(.MTU_WORDS(MTU_WORDS), .NUM_QP(NUM_QP), .RX_BUFS(RX_BUFS))
    u_reg (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid),
        .s_wready(s_wready), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid),
        .s_rready(s_rready),
        .wq_base(wq_base), .wq_count(wq_count), .cq_base(cq_base),
        .mem_limit(mem_limit), .credit_lim(credit_lim),
        .inject_skip(inject_skip), .start(start), .abort(abort),
        .all_done(all_done),
        .st_wqe(st_wqe), .st_pkt(st_pkt), .st_txw(st_txw), .st_rxw(st_rxw),
        .st_cqe(st_cqe), .st_err(st_err), .st_seq(st_seq), .st_frm(st_frm),
        .st_crstall(st_crstall), .st_lkstall(st_lkstall),
        .st_memstall(tx_memstall + rx_memstall),
        .err_code(err_code), .err_index(err_index),
        .bus_err(tx_bus_err || rx_bus_err),
        .busy(busy), .cycles(cycles), .irq(irq)
    );

endmodule
