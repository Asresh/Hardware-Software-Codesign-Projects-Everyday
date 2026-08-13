// -----------------------------------------------------------------------------
// sfu_regfile.v
// The MMIO mailbox: a small memory-mapped register block the host writes to set
// up a job (request/result ring bases, ring capacity, head indices, request
// count) and reads to observe completion and the measured cycle count. A write
// of CTRL.START raises a one-cycle doorbell pulse to the sequencer; STATUS
// exposes done / busy / irq; a completion pulse from the sequencer sets the
// sticky DONE bit and, when enabled, latches an interrupt the host clears via
// CTRL.IRQ_CLR.
// -----------------------------------------------------------------------------
`default_nettype none

module sfu_regfile #(
    parameter integer LANES = 4
) (
    input  wire        clk,
    input  wire        rst_n,

    // MMIO slave
    input  wire        mmio_sel,
    input  wire        mmio_write,
    input  wire [7:0]  mmio_addr,
    input  wire [31:0] mmio_wdata,
    output reg  [31:0] mmio_rdata,

    // job descriptor -> sequencer
    output reg  [31:0] req_base,
    output reg  [31:0] res_base,
    output reg  [31:0] ring_cap,
    output reg  [31:0] req_head,
    output reg  [31:0] res_head,
    output reg  [31:0] count,
    output reg         start,

    // status <- sequencer
    input  wire        seq_busy,
    input  wire        seq_done_pulse,
    input  wire [31:0] seq_cycles,
    output wire        irq
);
    localparam [7:0] REG_IDENT=8'h00, REG_CTRL=8'h04, REG_STATUS=8'h08,
        REG_REQ_BASE=8'h0C, REG_RES_BASE=8'h10, REG_RING_CAP=8'h14,
        REG_REQ_HEAD=8'h18, REG_RES_HEAD=8'h1C, REG_COUNT=8'h20,
        REG_CYCLES=8'h24, REG_LANES=8'h28;

    localparam [31:0] CTRL_START=32'h1, CTRL_IRQ_EN=32'h2, CTRL_IRQ_CLR=32'h4;
    localparam [31:0] IDENT_VALUE=32'h5C1D0007;

    reg done_latched, irq_en, irq_pending;

    wire wr = mmio_sel & mmio_write;
    assign irq = irq_pending;

    always @(posedge clk) begin
        if (!rst_n) begin
            req_base<=0; res_base<=0; ring_cap<=0;
            req_head<=0; res_head<=0; count<=0;
            start<=1'b0; done_latched<=1'b0; irq_en<=1'b0; irq_pending<=1'b0;
        end else begin
            start <= 1'b0;                        // one-cycle doorbell

            if (wr) begin
                case (mmio_addr)
                    REG_REQ_BASE: req_base <= mmio_wdata;
                    REG_RES_BASE: res_base <= mmio_wdata;
                    REG_RING_CAP: ring_cap <= mmio_wdata;
                    REG_REQ_HEAD: req_head <= mmio_wdata;
                    REG_RES_HEAD: res_head <= mmio_wdata;
                    REG_COUNT:    count    <= mmio_wdata;
                    REG_CTRL: begin
                        if (mmio_wdata & CTRL_START) begin
                            start        <= 1'b1;
                            done_latched <= 1'b0;    // new job clears done
                            irq_pending  <= 1'b0;
                        end
                        if (mmio_wdata & CTRL_IRQ_EN)  irq_en <= 1'b1;
                        if (mmio_wdata & CTRL_IRQ_CLR) begin
                            irq_pending  <= 1'b0;
                            done_latched <= 1'b0;
                        end
                    end
                    default: ;
                endcase
            end

            if (seq_done_pulse) begin
                done_latched <= 1'b1;
                if (irq_en) irq_pending <= 1'b1;
            end
        end
    end

    always @(*) begin
        case (mmio_addr)
            REG_IDENT:    mmio_rdata = IDENT_VALUE;
            REG_STATUS:   mmio_rdata = {29'd0, irq_pending, seq_busy, done_latched};
            REG_REQ_BASE: mmio_rdata = req_base;
            REG_RES_BASE: mmio_rdata = res_base;
            REG_RING_CAP: mmio_rdata = ring_cap;
            REG_REQ_HEAD: mmio_rdata = req_head;
            REG_RES_HEAD: mmio_rdata = res_head;
            REG_COUNT:    mmio_rdata = count;
            REG_CYCLES:   mmio_rdata = seq_cycles;
            REG_LANES:    mmio_rdata = LANES[31:0];
            default:      mmio_rdata = 32'h0;
        endcase
    end
endmodule

`default_nettype wire
