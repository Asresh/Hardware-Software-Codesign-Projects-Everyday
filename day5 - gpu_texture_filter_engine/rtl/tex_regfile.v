// -----------------------------------------------------------------------------
// tex_regfile.v
// Mailbox + doorbell control plane. The host writes a job descriptor into the
// mailbox registers, then rings the doorbell (CTRL.START); the engine runs and,
// on completion, latches the cycle count and raises a level interrupt. The host
// interrupt handler reads STATUS, consumes CYCLES and writes CTRL.IRQ_CLR to
// acknowledge. This is the whole software-visible surface of the accelerator.
// -----------------------------------------------------------------------------
`default_nettype none

module tex_regfile #(
    parameter integer ADDR_WIDTH = 20,
    parameter [31:0]  IDENT_VALUE = 32'h5B170005
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- MMIO mailbox port ----
    input  wire                   mmio_sel,
    input  wire                   mmio_write,
    input  wire [7:0]             mmio_addr,
    input  wire [31:0]            mmio_wdata,
    output reg  [31:0]            mmio_rdata,

    // ---- descriptor to the sequencer ----
    output reg                    start,          // 1-cycle doorbell pulse
    output reg  [ADDR_WIDTH-1:0]  src_base,
    output reg  [ADDR_WIDTH-1:0]  dst_base,
    output reg  [15:0]            src_w,
    output reg  [15:0]            src_h,
    output reg  [15:0]            dst_w,
    output reg  [15:0]            dst_h,
    output reg  [31:0]            scale_x,
    output reg  [31:0]            scale_y,

    // ---- status from the sequencer ----
    input  wire                   busy,
    input  wire                   done_set,       // 1-cycle completion pulse
    input  wire [31:0]            cycles,

    output wire                   irq
);
    localparam [7:0]
        REG_IDENT=8'h00, REG_CTRL=8'h04, REG_STATUS=8'h08,
        REG_SRC=8'h0C,   REG_DST=8'h10,  REG_SRC_W=8'h14,
        REG_SRC_H=8'h18, REG_DST_W=8'h1C, REG_DST_H=8'h20,
        REG_SCALE_X=8'h24, REG_SCALE_Y=8'h28, REG_CYCLES=8'h2C;

    reg done_flag;
    reg irq_en;

    wire wr = mmio_sel & mmio_write;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start<=0; src_base<=0; dst_base<=0;
            src_w<=0; src_h<=0; dst_w<=0; dst_h<=0;
            scale_x<=0; scale_y<=0;
            done_flag<=0; irq_en<=0;
        end else begin
            start <= 1'b0;                         // default: pulse
            if (done_set) done_flag <= 1'b1;       // sticky until acknowledged
            if (wr) begin
                case (mmio_addr)
                    REG_CTRL: begin
                        if (mmio_wdata[0] && !busy) begin
                            start     <= 1'b1;      // ring doorbell
                            done_flag <= 1'b0;      // clear stale completion
                        end
                        if (mmio_wdata[1]) irq_en <= 1'b1;
                        if (mmio_wdata[2]) done_flag <= 1'b0;   // IRQ_CLR
                    end
                    REG_SRC:     src_base <= mmio_wdata[ADDR_WIDTH-1:0];
                    REG_DST:     dst_base <= mmio_wdata[ADDR_WIDTH-1:0];
                    REG_SRC_W:   src_w    <= mmio_wdata[15:0];
                    REG_SRC_H:   src_h    <= mmio_wdata[15:0];
                    REG_DST_W:   dst_w    <= mmio_wdata[15:0];
                    REG_DST_H:   dst_h    <= mmio_wdata[15:0];
                    REG_SCALE_X: scale_x  <= mmio_wdata;
                    REG_SCALE_Y: scale_y  <= mmio_wdata;
                    default: ;
                endcase
            end
        end
    end

    always @(*) begin
        case (mmio_addr)
            REG_IDENT:   mmio_rdata = IDENT_VALUE;
            REG_STATUS:  mmio_rdata = {29'b0, irq, busy, done_flag};
            REG_SRC:     mmio_rdata = {{(32-ADDR_WIDTH){1'b0}}, src_base};
            REG_DST:     mmio_rdata = {{(32-ADDR_WIDTH){1'b0}}, dst_base};
            REG_SRC_W:   mmio_rdata = {16'b0, src_w};
            REG_SRC_H:   mmio_rdata = {16'b0, src_h};
            REG_DST_W:   mmio_rdata = {16'b0, dst_w};
            REG_DST_H:   mmio_rdata = {16'b0, dst_h};
            REG_SCALE_X: mmio_rdata = scale_x;
            REG_SCALE_Y: mmio_rdata = scale_y;
            REG_CYCLES:  mmio_rdata = cycles;
            default:     mmio_rdata = 32'b0;
        endcase
    end

    assign irq = done_flag & irq_en;
endmodule

`default_nettype wire
