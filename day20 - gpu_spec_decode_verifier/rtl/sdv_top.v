// ===========================================================================
// sdv_top.v - speculative-decoding draft-tree verifier, top level.
//
//   draft device --AXI4-Stream(128b)--> [ node array ] --> [ argmax tree ]
//                                             |                  |
//                                        [ walk FSM ] -----------+
//                                             |
//                                        [ result FIFO ] --> AXI4-Stream out
//                                             |
//   host CPU  --APB3--> [ control / status / histogram ] --> irq
//
// The whole point of the arrangement is that the host never touches the tree.
// It programs the acceptance policy once, points the draft device's output at
// the ingress link, and gets back the accepted tokens, the bonus token and the
// KV-cache rows to keep - by which time it has spent no cycles walking
// pointers and the target GPU can start its next forward pass.
// ===========================================================================
`default_nettype none
`include "sdv_defs.vh"

module sdv_top #(
    parameter integer MAX_NODES = `SDV_MAX_NODES,
    parameter integer MAX_DEPTH = `SDV_MAX_DEPTH
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- APB3 control plane ----------------------------------------------
    input  wire         psel,
    input  wire         penable,
    input  wire         pwrite,
    input  wire [11:0]  paddr,
    input  wire [31:0]  pwdata,
    output wire [31:0]  prdata,
    output wire         pready,
    output wire         pslverr,

    // ---- AXI4-Stream ingress: one draft-tree node record per beat ---------
    input  wire         s_tvalid,
    output wire         s_tready,
    input  wire [127:0] s_tdata,
    input  wire         s_tlast,

    // ---- AXI4-Stream egress: accepted tokens then a trailer ---------------
    output wire         m_tvalid,
    input  wire         m_tready,
    output wire [127:0] m_tdata,
    output wire         m_tlast,

    output wire         irq,
    output wire         dbg_fifo_ovf
);
    // index and depth-counter widths
    localparam integer IW = (MAX_NODES <= 2)   ? 1 : (MAX_NODES <= 4)   ? 2 :
                            (MAX_NODES <= 8)   ? 3 : (MAX_NODES <= 16)  ? 4 :
                            (MAX_NODES <= 32)  ? 5 : (MAX_NODES <= 64)  ? 6 :
                            (MAX_NODES <= 128) ? 7 : (MAX_NODES <= 256) ? 8 : 9;
    localparam integer DW = (MAX_DEPTH < 2)   ? 1 : (MAX_DEPTH < 4)   ? 2 :
                            (MAX_DEPTH < 8)   ? 3 : (MAX_DEPTH < 16)  ? 4 :
                            (MAX_DEPTH < 32)  ? 5 : (MAX_DEPTH < 64)  ? 6 : 7;
    // the FIFO holds a whole job: MAX_DEPTH tokens plus one trailer
    localparam integer FD = (MAX_DEPTH + 2 <= 4)  ? 4  :
                            (MAX_DEPTH + 2 <= 8)  ? 8  :
                            (MAX_DEPTH + 2 <= 16) ? 16 :
                            (MAX_DEPTH + 2 <= 32) ? 32 :
                            (MAX_DEPTH + 2 <= 64) ? 64 : 128;
    localparam integer FA = (FD == 4) ? 2 : (FD == 8)  ? 3 : (FD == 16) ? 4 :
                            (FD == 32) ? 5 : (FD == 64) ? 6 : 7;

    wire        en, soft_rst;
    wire [1:0]  cfg_mode;
    wire [15:0] cfg_th_abs, cfg_th_rel, cfg_max_acc;

    wire         c_push, c_empty, c_full, c_pop;
    wire [128:0] c_din, c_dout;

    wire         st_busy, st_srcstall, st_bpstall, st_job_done, st_node_inc;
    wire         st_accept_inc, st_err_job, st_clamp_job;
    wire [DW-1:0] st_accept_depth;
    wire [2:0]   st_errcode, dbg_state;
    wire [31:0]  st_last_cyc;
    wire [15:0]  st_last_acc;

    wire core_rst_n = rst_n && !soft_rst;

    sdv_core #(.N(MAX_NODES), .IW(IW), .D(MAX_DEPTH), .DW(DW)) u_core (
        .clk(clk), .rst_n(core_rst_n),
        .en(en), .cfg_mode(cfg_mode), .cfg_th_abs(cfg_th_abs),
        .cfg_th_rel(cfg_th_rel), .cfg_max_acc(cfg_max_acc),
        .s_tvalid(s_tvalid), .s_tready(s_tready),
        .s_tdata(s_tdata), .s_tlast(s_tlast),
        .fifo_push(c_push), .fifo_din(c_din), .fifo_empty(c_empty),
        .st_busy(st_busy), .st_srcstall(st_srcstall), .st_bpstall(st_bpstall),
        .st_job_done(st_job_done), .st_node_inc(st_node_inc),
        .st_accept_inc(st_accept_inc), .st_accept_depth(st_accept_depth),
        .st_err_job(st_err_job), .st_clamp_job(st_clamp_job),
        .st_errcode(st_errcode), .st_last_cyc(st_last_cyc),
        .st_last_acc(st_last_acc), .dbg_state(dbg_state)
    );

    sdv_fifo #(.W(129), .DEPTH(FD), .AW(FA)) u_fifo (
        .clk(clk), .rst_n(core_rst_n),
        .push(c_push), .din(c_din),
        .pop(c_pop), .dout(c_dout),
        .empty(c_empty), .full(c_full), .ovf(dbg_fifo_ovf)
    );

    sdv_emit u_emit (
        .clk(clk), .rst_n(core_rst_n),
        .fifo_empty(c_empty), .fifo_dout(c_dout), .fifo_pop(c_pop),
        .m_tvalid(m_tvalid), .m_tready(m_tready),
        .m_tdata(m_tdata), .m_tlast(m_tlast)
    );

    sdv_apb_regs #(.N(MAX_NODES), .D(MAX_DEPTH), .DW(DW)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .prdata(prdata), .pready(pready), .pslverr(pslverr),
        .en(en), .cfg_mode(cfg_mode), .cfg_th_abs(cfg_th_abs),
        .cfg_th_rel(cfg_th_rel), .cfg_max_acc(cfg_max_acc),
        .soft_rst(soft_rst),
        .st_busy(st_busy), .st_srcstall(st_srcstall), .st_bpstall(st_bpstall),
        .st_job_done(st_job_done), .st_node_inc(st_node_inc),
        .st_accept_inc(st_accept_inc), .st_accept_depth(st_accept_depth),
        .st_err_job(st_err_job), .st_clamp_job(st_clamp_job),
        .st_errcode(st_errcode), .st_last_cyc(st_last_cyc),
        .st_last_acc(st_last_acc),
        .core_busy(st_busy), .eg_empty(c_empty),
        .irq(irq)
    );

endmodule
`default_nettype wire
