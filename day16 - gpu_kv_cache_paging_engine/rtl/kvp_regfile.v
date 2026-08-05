// ============================================================================
// kvp_regfile.v - MMIO control/status plane of the KV-cache paging engine.
//
//   The host uses it to describe a batch (request array, result array, block
//   table base/stride), to seed the physical-block pool one block at a time
//   through FREE_PUSH, to kick the walk (CTRL.START), and to read back the
//   cumulative paging statistics that a serving runtime actually wants: how many
//   translations, how many served from the on-chip cache, how many block-table
//   walks, how many blocks allocated / returned, how many errors.
//
//   Interrupt: DONE, out-of-memory (free pool exhausted) and bus-error are
//   sticky status bits; IRQ is their OR gated by CTRL.IRQ_EN and each is cleared
//   write-1-to-clear through IRQ_ACK.  A serving runtime therefore learns "the
//   KV cache is full" from an interrupt instead of polling.
// ============================================================================
`default_nettype none

module kvp_regfile #(
    parameter integer PHYS_W = 24
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- MMIO ----
    input  wire        reg_wr,
    input  wire        reg_rd,
    input  wire [7:0]  reg_addr,
    input  wire [31:0] reg_wdata,
    output wire [31:0] reg_rdata,
    output wire        irq,

    // ---- to the core ----
    output reg         start,
    output reg         soft_rst,
    output reg  [31:0] req_base,
    output reg  [31:0] res_base,
    output reg  [31:0] req_count,
    output reg  [31:0] bt_base,
    output reg  [15:0] bt_stride,

    // ---- from the core ----
    input  wire        busy,
    input  wire        done_pulse,
    input  wire        err_oom,
    input  wire        err_bus,
    input  wire [31:0] stat_reqs,
    input  wire [31:0] stat_xlates,
    input  wire [31:0] stat_hits,
    input  wire [31:0] stat_misses,
    input  wire [31:0] stat_allocs,
    input  wire [31:0] stat_frees,
    input  wire [31:0] stat_errs,
    input  wire [31:0] res_words,
    input  wire [31:0] last_cyc,

    // ---- free-list host port ----
    output reg               host_push,
    output reg [PHYS_W-1:0]  host_push_blk,
    input  wire [31:0]       free_count
);
    `include "kvp_defs.vh"

    reg irq_en, st_done, st_oom, st_bus;

    wire wr_hit = reg_wr;

    always @(posedge clk) begin
        start     <= 1'b0;
        soft_rst  <= 1'b0;
        host_push <= 1'b0;

        if (!rst_n) begin
            irq_en   <= 1'b0;
            st_done  <= 1'b0;
            st_oom   <= 1'b0;
            st_bus   <= 1'b0;
            req_base <= 32'd0; res_base <= 32'd0; req_count <= 32'd0;
            bt_base  <= 32'd0; bt_stride <= 16'd0;
            host_push_blk <= {PHYS_W{1'b0}};
        end else begin
            if (wr_hit) begin
                case (reg_addr)
                R_CTRL: begin
                    if (reg_wdata[CTRL_START_B] && !busy) start <= 1'b1;
                    if (reg_wdata[CTRL_SRST_B])            soft_rst <= 1'b1;
                    irq_en <= reg_wdata[CTRL_IRQEN_B];
                end
                R_REQ_BASE:  req_base  <= reg_wdata;
                R_RES_BASE:  res_base  <= reg_wdata;
                R_REQ_COUNT: req_count <= reg_wdata;
                R_BT_BASE:   bt_base   <= reg_wdata;
                R_BT_STRIDE: bt_stride <= reg_wdata[15:0];
                R_FREE_PUSH: begin
                    host_push     <= 1'b1;
                    host_push_blk <= reg_wdata[PHYS_W-1:0];
                end
                R_IRQ_ACK: begin
                    if (reg_wdata[ST_DONE_B]) st_done <= 1'b0;
                    if (reg_wdata[ST_OOM_B])  st_oom  <= 1'b0;
                    if (reg_wdata[ST_BUS_B])  st_bus  <= 1'b0;
                end
                default: ;
                endcase
            end

            // sticky event capture (wins over a same-cycle W1C of another bit)
            if (done_pulse) st_done <= 1'b1;
            if (err_oom)    st_oom  <= 1'b1;
            if (err_bus)    st_bus  <= 1'b1;
        end
    end

    assign irq = irq_en & (st_done | st_oom | st_bus);

    wire [31:0] status = {27'd0, irq, st_bus, st_oom, st_done, busy};

    reg [31:0] rdata_r;
    always @(*) begin
        case (reg_addr)
        R_STATUS:      rdata_r = status;
        R_REQ_BASE:    rdata_r = req_base;
        R_RES_BASE:    rdata_r = res_base;
        R_REQ_COUNT:   rdata_r = req_count;
        R_BT_BASE:     rdata_r = bt_base;
        R_BT_STRIDE:   rdata_r = {16'd0, bt_stride};
        R_FREE_COUNT:  rdata_r = free_count;
        R_STAT_REQS:   rdata_r = stat_reqs;
        R_STAT_XLATES: rdata_r = stat_xlates;
        R_STAT_HITS:   rdata_r = stat_hits;
        R_STAT_MISSES: rdata_r = stat_misses;
        R_STAT_ALLOCS: rdata_r = stat_allocs;
        R_STAT_FREES:  rdata_r = stat_frees;
        R_STAT_ERRS:   rdata_r = stat_errs;
        R_LAST_CYC:    rdata_r = last_cyc;
        R_RES_WORDS:   rdata_r = res_words;
        R_VERSION:     rdata_r = KVP_VERSION;
        default:       rdata_r = 32'd0;
        endcase
    end
    assign reg_rdata = reg_rd ? rdata_r : 32'd0;
endmodule

`default_nettype wire
