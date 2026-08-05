// ============================================================================
// kvp_top.v - KV-cache paging engine (paged-attention block-table accelerator).
//
//   Host side : a small MMIO register file (kvp_regfile)
//   Memory    : one Wishbone B4 classic master (kvp_wb_master) shared by the
//               request fetch, the block-table walk and the result writeback
//   Datapath  : kvp_core sequencer + kvp_tlb translation cache + kvp_freelist
//               physical-block allocator
//
//   The engine is the address-translation front end of a paged KV cache: the
//   attention kernels want physical KV-block numbers, the serving runtime thinks
//   in (sequence, logical block) pairs, and this block turns the second into the
//   first at bus rate while owning block allocation and release.
// ============================================================================
`default_nettype none

module kvp_top #(
    parameter integer SETS       = 16,   // translation-cache sets
    parameter integer WAYS       = 4,    // ways per set
    parameter integer SEQ_W      = 12,   // sequence-id width
    parameter integer LOG_W      = 16,   // logical-block width
    parameter integer PHYS_W     = 24,   // physical-block width
    parameter integer FREE_DEPTH = 512,  // physical blocks the pool can hold
    parameter integer WB_TIMEOUT = 256   // unacknowledged-cycle watchdog
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- MMIO control/status ----
    input  wire        reg_wr,
    input  wire        reg_rd,
    input  wire [7:0]  reg_addr,
    input  wire [31:0] reg_wdata,
    output wire [31:0] reg_rdata,
    output wire        irq,

    // ---- Wishbone B4 classic master ----
    output wire        wb_cyc_o,
    output wire        wb_stb_o,
    output wire        wb_we_o,
    output wire [31:0] wb_adr_o,
    output wire [31:0] wb_dat_o,
    output wire [3:0]  wb_sel_o,
    input  wire        wb_ack_i,
    input  wire [31:0] wb_dat_i,
    input  wire        wb_err_i
);
    localparam integer KEY_W = SEQ_W + LOG_W;

    // ---- regfile <-> core ----
    wire        start, soft_rst;
    wire [31:0] req_base, res_base, req_count, bt_base;
    wire [15:0] bt_stride;
    wire        busy, done_pulse, err_oom, err_bus;
    wire [31:0] stat_reqs, stat_xlates, stat_hits, stat_misses;
    wire [31:0] stat_allocs, stat_frees, stat_errs, res_words, last_cyc;

    // ---- core <-> tlb ----
    wire [KEY_W-1:0]  tlb_key;
    wire              tlb_touch, tlb_fill, tlb_inv, tlb_flush_core, tlb_hit;
    wire [PHYS_W-1:0] tlb_fill_phys, tlb_phys;

    // ---- core/host <-> freelist ----
    wire              core_push, core_pop;
    wire [PHYS_W-1:0] core_push_blk, fl_top;
    wire              fl_empty, fl_full;
    wire [31:0]       free_count;
    wire              host_push;
    wire [PHYS_W-1:0] host_push_blk;

    // ---- core <-> wishbone master ----
    wire        m_req, m_we, m_done, m_err;
    wire [31:0] m_addr, m_wdata, m_rdata, m_xacts;

    kvp_regfile #(.PHYS_W(PHYS_W)) u_regfile (
        .clk(clk), .rst_n(rst_n),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr),
        .reg_wdata(reg_wdata), .reg_rdata(reg_rdata), .irq(irq),
        .start(start), .soft_rst(soft_rst),
        .req_base(req_base), .res_base(res_base), .req_count(req_count),
        .bt_base(bt_base), .bt_stride(bt_stride),
        .busy(busy), .done_pulse(done_pulse), .err_oom(err_oom), .err_bus(err_bus),
        .stat_reqs(stat_reqs), .stat_xlates(stat_xlates), .stat_hits(stat_hits),
        .stat_misses(stat_misses), .stat_allocs(stat_allocs), .stat_frees(stat_frees),
        .stat_errs(stat_errs), .res_words(res_words), .last_cyc(last_cyc),
        .host_push(host_push), .host_push_blk(host_push_blk), .free_count(free_count)
    );

    kvp_core #(.SEQ_W(SEQ_W), .LOG_W(LOG_W), .PHYS_W(PHYS_W)) u_core (
        .clk(clk), .rst_n(rst_n),
        .start(start), .stat_clr(soft_rst),
        .req_base(req_base), .res_base(res_base), .req_count(req_count),
        .bt_base(bt_base), .bt_stride(bt_stride),
        .busy(busy), .done_pulse(done_pulse), .err_oom(err_oom), .err_bus(err_bus),
        .stat_reqs(stat_reqs), .stat_xlates(stat_xlates), .stat_hits(stat_hits),
        .stat_misses(stat_misses), .stat_allocs(stat_allocs), .stat_frees(stat_frees),
        .stat_errs(stat_errs), .res_words(res_words), .last_cyc(last_cyc),
        .tlb_key(tlb_key), .tlb_touch(tlb_touch), .tlb_fill(tlb_fill),
        .tlb_fill_phys(tlb_fill_phys), .tlb_inv(tlb_inv), .tlb_flush(tlb_flush_core),
        .tlb_hit(tlb_hit), .tlb_phys(tlb_phys),
        .fl_push(core_push), .fl_push_blk(core_push_blk), .fl_pop(core_pop),
        .fl_top(fl_top), .fl_empty(fl_empty),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_done(m_done), .m_err(m_err), .m_rdata(m_rdata)
    );

    // a soft reset also flushes the translation cache and drops the block pool
    kvp_tlb #(.SETS(SETS), .WAYS(WAYS), .KEY_W(KEY_W), .PHYS_W(PHYS_W)) u_tlb (
        .clk(clk), .rst_n(rst_n),
        .probe_key(tlb_key), .probe_hit(tlb_hit), .probe_phys(tlb_phys),
        .touch_en(tlb_touch), .fill_en(tlb_fill), .fill_phys(tlb_fill_phys),
        .inv_en(tlb_inv), .flush_en(tlb_flush_core | soft_rst)
    );

    kvp_freelist #(.DEPTH(FREE_DEPTH), .PHYS_W(PHYS_W)) u_freelist (
        .clk(clk), .rst_n(rst_n), .clear(soft_rst),
        .push_en(core_push | host_push),
        .push_blk(core_push ? core_push_blk : host_push_blk),
        .pop_en(core_pop),
        .top_blk(fl_top), .empty(fl_empty), .full(fl_full), .count(free_count)
    );

    kvp_wb_master #(.TIMEOUT(WB_TIMEOUT)) u_wb (
        .clk(clk), .rst_n(rst_n),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_done(m_done), .m_err(m_err), .m_rdata(m_rdata), .m_xacts(m_xacts),
        .wb_cyc_o(wb_cyc_o), .wb_stb_o(wb_stb_o), .wb_we_o(wb_we_o),
        .wb_adr_o(wb_adr_o), .wb_dat_o(wb_dat_o), .wb_sel_o(wb_sel_o),
        .wb_ack_i(wb_ack_i), .wb_dat_i(wb_dat_i), .wb_err_i(wb_err_i)
    );

    wire _unused = fl_full | (|m_xacts);
endmodule

`default_nettype wire
