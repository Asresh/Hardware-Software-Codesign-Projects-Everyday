// ============================================================================
// emb_top - sharded embedding gather-reduce engine, top level.
//
//   host  --MMIO-->  emb_regfile  ----->  emb_core  -----> emb_accum
//                        ^                  |  |              ^  |
//                        |                  |  |              |  |
//                       irq        emb_axi_read  emb_axi_write   |
//                                        |               ^-------+
//                                        v            (pooled vector)
//                                  shared device memory (AXI4)
//
// One AXI4 read master serves descriptor fetches, index-list fetches and row
// gathers; one AXI4 write master carries the pooled vectors back.  The datapath
// between them is the double-buffered accumulator, which is where the row fetch
// of one index overlaps the pooling fold of the previous one.
// ============================================================================
`include "emb_defs.vh"

module emb_top #(
    parameter DIM     = `EMB_DIM,
    parameter LANES   = `EMB_LANES,
    parameter MAX_BAG = `EMB_MAX_BAG,
    parameter AW      = 32
) (
    input  wire            clk,
    input  wire            rst,

    // ---- MMIO control plane --------------------------------------------
    input  wire            reg_sel,
    input  wire            reg_we,
    input  wire [7:0]      reg_addr,
    input  wire [31:0]     reg_wdata,
    output wire [31:0]     reg_rdata,
    output wire            irq,

    // ---- AXI4 master, read channels ------------------------------------
    output wire            m_arvalid,
    input  wire            m_arready,
    output wire [AW-1:0]   m_araddr,
    output wire [7:0]      m_arlen,
    output wire [2:0]      m_arsize,
    output wire [1:0]      m_arburst,
    input  wire            m_rvalid,
    output wire            m_rready,
    input  wire [LANES*32-1:0] m_rdata,
    input  wire [1:0]      m_rresp,
    input  wire            m_rlast,

    // ---- AXI4 master, write channels -----------------------------------
    output wire            m_awvalid,
    input  wire            m_awready,
    output wire [AW-1:0]   m_awaddr,
    output wire [7:0]      m_awlen,
    output wire [2:0]      m_awsize,
    output wire [1:0]      m_awburst,
    output wire            m_wvalid,
    input  wire            m_wready,
    output wire [LANES*32-1:0] m_wdata,
    output wire [LANES*4-1:0]  m_wstrb,
    output wire            m_wlast,
    input  wire            m_bvalid,
    output wire            m_bready,
    input  wire [1:0]      m_bresp
);
    localparam integer DW     = LANES * 32;
    localparam integer CHUNKS = DIM / LANES;

    function integer clog2u;
        input integer v;
        integer i;
        begin
            clog2u = 0;
            for (i = 1; i < v; i = i * 2) clog2u = clog2u + 1;
        end
    endfunction
    localparam integer CW    = (clog2u(CHUNKS) < 1) ? 1 : clog2u(CHUNKS);
    localparam integer LOG2L = clog2u(LANES);

    // ------------------------------------------------------ regfile <-> core
    wire        start, single_buf;
    wire [31:0] desc_base, desc_count, idx_base, tab_base, out_base;
    wire [31:0] shard_lo, shard_hi, tab_rows;
    wire        core_busy, core_fin;
    wire        err_baglen, err_index, err_bus;
    wire        ev_desc, ev_idx, ev_local, ev_remote, ev_invalid;

    // ------------------------------------------------------ core <-> masters
    wire            rd_req_valid, rd_req_ready;
    wire [AW-1:0]   rd_req_addr;
    wire [7:0]      rd_req_len;
    wire            rd_d_valid, rd_d_ready, rd_d_last;
    wire [DW-1:0]   rd_d_data;
    wire            rd_err, rd_timeout, rd_busy;

    wire            wr_req_valid, wr_req_ready;
    wire [AW-1:0]   wr_req_addr;
    wire [7:0]      wr_req_len;
    wire            wr_done, wr_err, wr_timeout, wr_busy;

    // ------------------------------------------------------ core <-> accum
    wire            ac_clr, ac_f_valid, ac_f_first, ac_f_avail, ac_busy;
    wire [DW-1:0]   ac_f_data;
    wire            ac_d_start;
    wire [31:0]     ac_d_count;
    wire [1:0]      ac_op;
    wire            ac_d_valid, ac_d_ready;
    wire [DW-1:0]   ac_d_data;
    wire            ac_d_done;

    wire ev_rbeat = rd_d_valid & rd_d_ready;
    wire ev_wbeat = ac_d_valid & ac_d_ready;

    emb_regfile #(.LANES(LANES), .CHUNKS(CHUNKS)) u_regs (
        .clk        (clk),
        .rst        (rst),
        .reg_sel    (reg_sel),
        .reg_we     (reg_we),
        .reg_addr   (reg_addr),
        .reg_wdata  (reg_wdata),
        .reg_rdata  (reg_rdata),
        .start      (start),
        .single_buf (single_buf),
        .desc_base  (desc_base),
        .desc_count (desc_count),
        .idx_base   (idx_base),
        .tab_base   (tab_base),
        .out_base   (out_base),
        .shard_lo   (shard_lo),
        .shard_hi   (shard_hi),
        .tab_rows   (tab_rows),
        .core_busy  (core_busy),
        .core_fin   (core_fin),
        .err_baglen (err_baglen),
        .err_index  (err_index),
        .err_bus    (err_bus),
        .ev_desc    (ev_desc),
        .ev_idx     (ev_idx),
        .ev_local   (ev_local),
        .ev_remote  (ev_remote),
        .ev_invalid (ev_invalid),
        .ev_rbeat   (ev_rbeat),
        .ev_wbeat   (ev_wbeat),
        .irq        (irq)
    );

    emb_core #(
        .DIM(DIM), .LANES(LANES), .MAX_BAG(MAX_BAG),
        .CHUNKS(CHUNKS), .CW(CW), .LOG2L(LOG2L), .AW(AW)
    ) u_core (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .single_buf   (single_buf),
        .desc_base    (desc_base),
        .desc_count   (desc_count),
        .idx_base     (idx_base),
        .tab_base     (tab_base),
        .out_base     (out_base),
        .shard_lo     (shard_lo),
        .shard_hi     (shard_hi),
        .tab_rows     (tab_rows),
        .busy         (core_busy),
        .fin          (core_fin),
        .err_baglen   (err_baglen),
        .err_index    (err_index),
        .err_bus      (err_bus),
        .ev_desc      (ev_desc),
        .ev_idx       (ev_idx),
        .ev_local     (ev_local),
        .ev_remote    (ev_remote),
        .ev_invalid   (ev_invalid),
        .rd_req_valid (rd_req_valid),
        .rd_req_ready (rd_req_ready),
        .rd_req_addr  (rd_req_addr),
        .rd_req_len   (rd_req_len),
        .rd_d_valid   (rd_d_valid),
        .rd_d_ready   (rd_d_ready),
        .rd_d_data    (rd_d_data),
        .rd_d_last    (rd_d_last),
        .rd_err       (rd_err),
        .rd_timeout   (rd_timeout),
        .rd_busy      (rd_busy),
        .wr_req_valid (wr_req_valid),
        .wr_req_ready (wr_req_ready),
        .wr_req_addr  (wr_req_addr),
        .wr_req_len   (wr_req_len),
        .wr_done      (wr_done),
        .wr_err       (wr_err),
        .wr_timeout   (wr_timeout),
        .wr_busy      (wr_busy),
        .ac_clr       (ac_clr),
        .ac_f_valid   (ac_f_valid),
        .ac_f_first   (ac_f_first),
        .ac_f_data    (ac_f_data),
        .ac_f_avail   (ac_f_avail),
        .ac_busy      (ac_busy),
        .ac_d_start   (ac_d_start),
        .ac_d_count   (ac_d_count),
        .ac_op        (ac_op)
    );

    emb_accum #(.LANES(LANES), .CHUNKS(CHUNKS), .CW(CW)) u_accum (
        .clk        (clk),
        .rst        (rst),
        .clr        (ac_clr),
        .op         (ac_op),
        .single_buf (single_buf),
        .f_avail    (ac_f_avail),
        .f_valid    (ac_f_valid),
        .f_first    (ac_f_first),
        .f_data     (ac_f_data),
        .f_row_done (),
        .busy       (ac_busy),
        .d_start    (ac_d_start),
        .d_count    (ac_d_count),
        .d_valid    (ac_d_valid),
        .d_ready    (ac_d_ready),
        .d_data     (ac_d_data),
        .d_done     (ac_d_done)
    );

    emb_axi_read #(.DW(DW), .AW(AW)) u_rd (
        .clk       (clk),
        .rst       (rst),
        .req_valid (rd_req_valid),
        .req_ready (rd_req_ready),
        .req_addr  (rd_req_addr),
        .req_len   (rd_req_len),
        .m_arvalid (m_arvalid),
        .m_arready (m_arready),
        .m_araddr  (m_araddr),
        .m_arlen   (m_arlen),
        .m_arsize  (m_arsize),
        .m_arburst (m_arburst),
        .m_rvalid  (m_rvalid),
        .m_rready  (m_rready),
        .m_rdata   (m_rdata),
        .m_rresp   (m_rresp),
        .m_rlast   (m_rlast),
        .d_valid   (rd_d_valid),
        .d_ready   (rd_d_ready),
        .d_data    (rd_d_data),
        .d_last    (rd_d_last),
        .err       (rd_err),
        .timeout   (rd_timeout),
        .busy      (rd_busy)
    );

    emb_axi_write #(.DW(DW), .AW(AW)) u_wr (
        .clk       (clk),
        .rst       (rst),
        .req_valid (wr_req_valid),
        .req_ready (wr_req_ready),
        .req_addr  (wr_req_addr),
        .req_len   (wr_req_len),
        .s_valid   (ac_d_valid),
        .s_ready   (ac_d_ready),
        .s_data    (ac_d_data),
        .m_awvalid (m_awvalid),
        .m_awready (m_awready),
        .m_awaddr  (m_awaddr),
        .m_awlen   (m_awlen),
        .m_awsize  (m_awsize),
        .m_awburst (m_awburst),
        .m_wvalid  (m_wvalid),
        .m_wready  (m_wready),
        .m_wdata   (m_wdata),
        .m_wstrb   (m_wstrb),
        .m_wlast   (m_wlast),
        .m_bvalid  (m_bvalid),
        .m_bready  (m_bready),
        .m_bresp   (m_bresp),
        .done      (wr_done),
        .err       (wr_err),
        .timeout   (wr_timeout),
        .busy      (wr_busy)
    );
endmodule
