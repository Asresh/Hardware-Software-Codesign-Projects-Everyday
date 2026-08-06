// ============================================================================
// kds_top - multi-GPU kernel-DAG scheduler / hardware command processor.
//
//   host  --AXI4-Lite slave-->  kds_regfile  --> kds_core --> kds_axil_master
//                                                  |               |
//                                       kds_node_mem (CAM)   shared memory
//                                       kds_scoreboard        (graph + results)
//                                       kds_placer
//                                       kds_devq
//
// One AXI4-Lite slave port for control, one AXI4-Lite master port for the graph
// and the results, one level-sensitive interrupt line. The two derived widths -
// node-index width and device-index width - are computed here so every
// submodule agrees on them.
// ============================================================================
`include "kds_defs.vh"

module kds_top #(
    parameter MAX_NODES = `KDS_MAX_NODES,
    parameter DEVICES   = `KDS_DEVICES
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- AXI4-Lite control slave -------------------------------------------
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

    // ---- AXI4-Lite memory master -------------------------------------------
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
    output wire [31:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output wire        m_rready,

    output wire        irq
);

    localparam NIDW       = (MAX_NODES > 1) ? $clog2(MAX_NODES) : 1;
    localparam DIDW       = (DEVICES   > 1) ? $clog2(DEVICES)   : 1;
    localparam DEPW       = (MAX_NODES + 31) / 32;
    localparam NODE_WORDS = DEPW + 2;
    localparam OUTSTANDING = 4;

    wire        start;
    wire [31:0] cfg_num_nodes, cfg_node_base, cfg_rslt_base;
    wire [2:0]  st_state;
    wire [3:0]  st_err;
    wire        st_busy, ev_done, ev_err;
    wire [31:0] c_makespan, c_dispatched, c_stall, c_depwait, c_maxconc;
    wire [31:0] c_serial, c_buscyc, c_fetchw, c_wbw;
    wire [DEVICES*32-1:0] c_devbusy_flat;

    wire        rd_req, rd_gnt, rd_valid;
    wire [31:0] rd_addr, rd_data;
    wire        wr_req, wr_gnt, wr_done;
    wire [31:0] wr_addr, wr_wdata;
    wire        mem_clr, mem_err;

    kds_regfile #(.MAX_NODES(MAX_NODES), .DEVICES(DEVICES)) u_rf (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid),
        .s_wready(s_wready), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid),
        .s_rready(s_rready),
        .start(start), .cfg_num_nodes(cfg_num_nodes),
        .cfg_node_base(cfg_node_base), .cfg_rslt_base(cfg_rslt_base),
        .st_state(st_state), .st_err(st_err), .st_busy(st_busy),
        .ev_done(ev_done), .ev_err(ev_err),
        .c_makespan(c_makespan), .c_dispatched(c_dispatched), .c_stall(c_stall),
        .c_depwait(c_depwait), .c_maxconc(c_maxconc), .c_serial(c_serial),
        .c_buscyc(c_buscyc), .c_fetchw(c_fetchw), .c_wbw(c_wbw),
        .c_devbusy_flat(c_devbusy_flat),
        .irq(irq)
    );

    kds_core #(.MAX_NODES(MAX_NODES), .DEVICES(DEVICES), .NIDW(NIDW),
               .DIDW(DIDW), .DEPW(DEPW), .NODE_WORDS(NODE_WORDS),
               .OUTSTANDING(OUTSTANDING)) u_core (
        .clk(clk), .rst_n(rst_n),
        .start(start), .cfg_num_nodes(cfg_num_nodes),
        .cfg_node_base(cfg_node_base), .cfg_rslt_base(cfg_rslt_base),
        .st_state(st_state), .st_err(st_err), .st_busy(st_busy),
        .ev_done(ev_done), .ev_err(ev_err),
        .c_makespan(c_makespan), .c_dispatched(c_dispatched), .c_stall(c_stall),
        .c_depwait(c_depwait), .c_maxconc(c_maxconc), .c_serial(c_serial),
        .c_buscyc(c_buscyc), .c_fetchw(c_fetchw), .c_wbw(c_wbw),
        .c_devbusy_flat(c_devbusy_flat),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_gnt(rd_gnt),
        .rd_valid(rd_valid), .rd_data(rd_data),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_wdata(wr_wdata),
        .wr_gnt(wr_gnt), .wr_done(wr_done),
        .mem_clr(mem_clr), .mem_err(mem_err)
    );

    kds_axil_master u_m (
        .clk(clk), .rst_n(rst_n),
        .clr(mem_clr),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_gnt(rd_gnt),
        .rd_valid(rd_valid), .rd_data(rd_data),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_wdata(wr_wdata),
        .wr_gnt(wr_gnt), .wr_done(wr_done),
        .err(mem_err),
        .m_awaddr(m_awaddr), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wvalid(m_wvalid),
        .m_wready(m_wready), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
        .m_bready(m_bready),
        .m_araddr(m_araddr), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rvalid(m_rvalid),
        .m_rready(m_rready)
    );

endmodule
