// ============================================================================
// p2p_regfile - AXI4-Lite control/status plane and run sequencer.
//
// The host's whole interaction with the engine is: build the work-queue ring
// in shared memory, point four registers at it, ring the doorbell, and wait
// for the interrupt. Everything the runtime wants to know afterwards - how
// many packets went out, how many words landed, how many completions were
// posted, and crucially how many cycles the transmitter spent waiting on
// credits versus waiting on the wire - is counted here as the transfer
// happens, so no timestamping pass is needed to work out where the link went.
//
// The stall counters are deliberately split. Credit stalls mean the *peer* is
// the bottleneck (too few receive buffers for the round-trip time) and are
// fixed by posting more buffers; link stalls mean the wire is the bottleneck
// and are not fixable from software at all. Collapsing them into one "stalled"
// number would hide the only actionable half.
// ============================================================================
`timescale 1ns/1ps
`include "p2p_defs.vh"

module p2p_regfile #(
    parameter MTU_WORDS = 16,
    parameter NUM_QP    = 4,
    parameter RX_BUFS   = 4
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- AXI4-Lite slave ----------------------------------------------------
    input  wire [11:0] s_awaddr,
    input  wire        s_awvalid,
    output reg         s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output reg         s_wready,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [11:0] s_araddr,
    input  wire        s_arvalid,
    output reg         s_arready,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rvalid,
    input  wire        s_rready,

    // ---- to the datapath ----------------------------------------------------
    output reg  [31:0] wq_base,
    output reg  [31:0] wq_count,
    output reg  [31:0] cq_base,
    output reg  [31:0] mem_limit,
    output reg  [4:0]  credit_lim,
    output reg         inject_skip,
    output reg         start,
    output reg         abort,

    // ---- from the datapath --------------------------------------------------
    input  wire        all_done,
    input  wire [31:0] st_wqe,
    input  wire [31:0] st_pkt,
    input  wire [31:0] st_txw,
    input  wire [31:0] st_rxw,
    input  wire [31:0] st_cqe,
    input  wire [31:0] st_err,
    input  wire [31:0] st_seq,
    input  wire [31:0] st_frm,
    input  wire [31:0] st_crstall,
    input  wire [31:0] st_lkstall,
    input  wire [31:0] st_memstall,
    input  wire [3:0]  err_code,
    input  wire [31:0] err_index,
    input  wire        bus_err,

    output reg         busy,
    output reg  [31:0] cycles,
    output wire        irq
);

    reg [1:0] irq_stat, irq_en;

    wire err_any = (err_code != `P2P_ERR_NONE) || bus_err ||
                   (st_seq != 32'd0) || (st_frm != 32'd0);

    assign irq = |(irq_stat & irq_en);

    wire [31:0] caps = {8'd0, RX_BUFS[7:0], NUM_QP[7:0], MTU_WORDS[7:0]};

    // ------------------------------------------------------------- write
    reg        aw_hit, w_hit;
    reg [11:0] aw_addr;
    reg [31:0] w_data;
    wire       do_wr = aw_hit && w_hit && !s_bvalid;

    // ------------------------------------------------------------- read
    reg [31:0] rd_mux;
    always @* begin
        case (s_araddr[7:0])
            `P2P_CTRL:        rd_mux = 32'd0;
            `P2P_STATUS:      rd_mux = {28'd0, (st_seq != 0), err_any,
                                        ~busy & (cycles != 0), busy};
            `P2P_WQ_BASE:     rd_mux = wq_base;
            `P2P_WQ_COUNT:    rd_mux = wq_count;
            `P2P_CQ_BASE:     rd_mux = cq_base;
            `P2P_MEM_LIMIT:   rd_mux = mem_limit;
            `P2P_CREDIT_LIM:  rd_mux = {27'd0, credit_lim};
            `P2P_INJECT:      rd_mux = {31'd0, inject_skip};
            `P2P_IRQ_EN:      rd_mux = {30'd0, irq_en};
            `P2P_IRQ_STAT:    rd_mux = {30'd0, irq_stat};
            `P2P_ERR_CODE:    rd_mux = {28'd0, err_code};
            `P2P_ERR_INFO:    rd_mux = err_index;
            `P2P_ST_WQE:      rd_mux = st_wqe;
            `P2P_ST_PKT:      rd_mux = st_pkt;
            `P2P_ST_TXW:      rd_mux = st_txw;
            `P2P_ST_RXW:      rd_mux = st_rxw;
            `P2P_ST_CQE:      rd_mux = st_cqe;
            `P2P_ST_ERR:      rd_mux = st_err;
            `P2P_ST_SEQ:      rd_mux = st_seq;
            `P2P_ST_CYCLES:   rd_mux = cycles;
            `P2P_ST_CRSTALL:  rd_mux = st_crstall;
            `P2P_ST_LKSTALL:  rd_mux = st_lkstall;
            `P2P_ST_MEMSTALL: rd_mux = st_memstall;
            `P2P_CAPS:        rd_mux = caps;
            default:          rd_mux = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_awready <= 1'b0; s_wready <= 1'b0; s_bvalid <= 1'b0;
            s_bresp <= 2'b00; s_arready <= 1'b0; s_rvalid <= 1'b0;
            s_rresp <= 2'b00; s_rdata <= 32'd0;
            aw_hit <= 1'b0; w_hit <= 1'b0; aw_addr <= 12'd0; w_data <= 32'd0;
            wq_base <= 0; wq_count <= 0; cq_base <= 0; mem_limit <= 32'hFFFF_FFFF;
            credit_lim <= RX_BUFS[4:0]; inject_skip <= 1'b0;
            start <= 1'b0; abort <= 1'b0; busy <= 1'b0; cycles <= 32'd0;
            irq_stat <= 2'b00; irq_en <= 2'b00;
        end else begin
            start <= 1'b0;
            abort <= 1'b0;

            // ---- run sequencing -------------------------------------------
            if (busy) begin
                cycles <= cycles + 32'd1;
                if (all_done) begin
                    busy        <= 1'b0;
                    irq_stat[0] <= 1'b1;
                    if (err_any) irq_stat[1] <= 1'b1;
                end
            end

            // ---- AW / W ----------------------------------------------------
            if (s_awvalid && !aw_hit && !s_bvalid) begin
                aw_hit  <= 1'b1;
                aw_addr <= s_awaddr;
                s_awready <= 1'b1;
            end else s_awready <= 1'b0;

            if (s_wvalid && !w_hit && !s_bvalid) begin
                w_hit  <= 1'b1;
                w_data <= s_wdata;
                s_wready <= 1'b1;
            end else s_wready <= 1'b0;

            if (do_wr) begin
                aw_hit   <= 1'b0;
                w_hit    <= 1'b0;
                s_bvalid <= 1'b1;
                s_bresp  <= 2'b00;
                case (aw_addr[7:0])
                    `P2P_CTRL: begin
                        if (w_data[0] && !busy) begin
                            start  <= 1'b1;
                            busy   <= 1'b1;
                            cycles <= 32'd0;
                        end
                        if (w_data[1]) begin
                            abort <= 1'b1;
                            busy  <= 1'b0;
                        end
                    end
                    `P2P_WQ_BASE:    wq_base    <= w_data;
                    `P2P_WQ_COUNT:   wq_count   <= w_data;
                    `P2P_CQ_BASE:    cq_base    <= w_data;
                    `P2P_MEM_LIMIT:  mem_limit  <= w_data;
                    `P2P_CREDIT_LIM: credit_lim <= (w_data[4:0] == 5'd0) ? 5'd1
                                                                         : w_data[4:0];
                    `P2P_INJECT:     inject_skip <= w_data[0];
                    `P2P_IRQ_EN:     irq_en      <= w_data[1:0];
                    `P2P_IRQ_STAT:   irq_stat    <= irq_stat & ~w_data[1:0];
                    default: ;   // read-only or unmapped: accepted, ignored
                endcase
            end else if (s_bvalid && s_bready) begin
                s_bvalid <= 1'b0;
            end

            // ---- AR / R ----------------------------------------------------
            if (s_arvalid && !s_rvalid && !s_arready) begin
                s_arready <= 1'b1;
                s_rdata   <= rd_mux;
                s_rvalid  <= 1'b1;
                s_rresp   <= 2'b00;
            end else begin
                s_arready <= 1'b0;
                if (s_rvalid && s_rready) s_rvalid <= 1'b0;
            end
        end
    end

endmodule
