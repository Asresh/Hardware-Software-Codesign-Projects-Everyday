// -----------------------------------------------------------------------------
// philox_regfile.v
// The MMIO mailbox: a small memory-mapped register block the host writes to set
// up a job (destination, draw count, 64-bit key, 128-bit base counter) and reads
// to observe completion and the measured cycle count. A write of CTRL.START
// raises a one-cycle doorbell pulse to the sequencer; STATUS exposes done / busy
// / irq; a completion pulse from the sequencer sets the sticky DONE bit and,
// when enabled, latches an interrupt that the host clears via CTRL.IRQ_CLR.
// -----------------------------------------------------------------------------
`default_nettype none

module philox_regfile #(
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
    output reg  [31:0] dst,
    output reg  [31:0] ndraws,
    output reg  [31:0] key0,
    output reg  [31:0] key1,
    output reg  [31:0] ctr0,
    output reg  [31:0] ctr1,
    output reg  [31:0] ctr2,
    output reg  [31:0] ctr3,
    output reg         start,

    // status <- sequencer
    input  wire        seq_busy,
    input  wire        seq_done_pulse,
    input  wire [31:0] seq_cycles,
    output wire        irq
);
    localparam [7:0] REG_IDENT=8'h00, REG_CTRL=8'h04, REG_STATUS=8'h08,
        REG_DST=8'h0C, REG_NDRAWS=8'h10, REG_KEY0=8'h14, REG_KEY1=8'h18,
        REG_CTR0=8'h1C, REG_CTR1=8'h20, REG_CTR2=8'h24, REG_CTR3=8'h28,
        REG_CYCLES=8'h2C, REG_LANES=8'h30;

    localparam [31:0] CTRL_START=32'h1, CTRL_IRQ_EN=32'h2, CTRL_IRQ_CLR=32'h4;
    localparam [31:0] IDENT_VALUE=32'h5B160006;

    reg done_latched, irq_en, irq_pending;

    wire wr = mmio_sel & mmio_write;
    assign irq = irq_pending;

    always @(posedge clk) begin
        if (!rst_n) begin
            dst<=0; ndraws<=0; key0<=0; key1<=0;
            ctr0<=0; ctr1<=0; ctr2<=0; ctr3<=0;
            start<=1'b0; done_latched<=1'b0; irq_en<=1'b0; irq_pending<=1'b0;
        end else begin
            start <= 1'b0;                       // one-cycle doorbell

            if (wr) begin
                case (mmio_addr)
                    REG_DST:    dst    <= mmio_wdata;
                    REG_NDRAWS: ndraws <= mmio_wdata;
                    REG_KEY0:   key0   <= mmio_wdata;
                    REG_KEY1:   key1   <= mmio_wdata;
                    REG_CTR0:   ctr0   <= mmio_wdata;
                    REG_CTR1:   ctr1   <= mmio_wdata;
                    REG_CTR2:   ctr2   <= mmio_wdata;
                    REG_CTR3:   ctr3   <= mmio_wdata;
                    REG_CTRL: begin
                        if (mmio_wdata & CTRL_START) begin
                            start        <= 1'b1;
                            done_latched <= 1'b0;   // new job clears done
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

            // completion from the sequencer sets sticky done + optional irq
            if (seq_done_pulse) begin
                done_latched <= 1'b1;
                if (irq_en) irq_pending <= 1'b1;
            end
        end
    end

    // combinational read mux
    always @(*) begin
        case (mmio_addr)
            REG_IDENT:  mmio_rdata = IDENT_VALUE;
            REG_STATUS: mmio_rdata = {29'd0, irq_pending, seq_busy, done_latched};
            REG_DST:    mmio_rdata = dst;
            REG_NDRAWS: mmio_rdata = ndraws;
            REG_KEY0:   mmio_rdata = key0;
            REG_KEY1:   mmio_rdata = key1;
            REG_CTR0:   mmio_rdata = ctr0;
            REG_CTR1:   mmio_rdata = ctr1;
            REG_CTR2:   mmio_rdata = ctr2;
            REG_CTR3:   mmio_rdata = ctr3;
            REG_CYCLES: mmio_rdata = seq_cycles;
            REG_LANES:  mmio_rdata = LANES[31:0];
            default:    mmio_rdata = 32'h0;
        endcase
    end
endmodule

`default_nettype wire
