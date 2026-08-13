// ===========================================================================
// mxq_csr - the MMIO control plane.
//
// Twenty-two registers on a simple selected/ready host bus.  The launch path
// is deliberately short: write the arguments, write CTRL.START, wait for the
// interrupt, read RETVAL.  Everything else in here is observability - six
// counters the firmware turns into a report, a latched trap cause and PC, a
// version, and a fold of the register map that is compared against the
// software header so the two cannot drift apart unnoticed.
//
// IRQ_STAT is write-1-to-clear and sticky, so a completion cannot be lost
// between the core halting and the host getting round to looking.
// ===========================================================================
`include "mxq_defs.vh"

module mxq_csr #(
    parameter IMEM_W = 12,
    parameter DMEM_W = 12
) (
    input  wire        clk,
    input  wire        rst_n,

    // host side
    input  wire        acc,          // this cycle is the access cycle
    input  wire        we,
    input  wire [5:0]  raddr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    // to / from the core
    output reg         start,
    output reg  [31:0] start_pc,
    output reg  [31:0] wdog,
    output reg  [31:0] arg0,
    output reg  [31:0] arg1,
    output reg  [31:0] arg2,
    output reg  [31:0] arg3,
    output reg         soft_rst,

    input  wire        running,
    input  wire        halted,
    input  wire        trapped,
    input  wire [3:0]  errcode,
    input  wire [31:0] trap_pc,
    input  wire [31:0] halt_pc,
    input  wire [31:0] retval,
    input  wire [31:0] c_cycles,
    input  wire [31:0] c_instret,
    input  wire [31:0] c_custom,
    input  wire [31:0] c_branch,
    input  wire [31:0] c_loads,
    input  wire [31:0] c_stores,

    output wire        irq
);
    localparam [7:0] IW8    = IMEM_W;
    localparam [7:0] DW8    = DMEM_W;
    localparam [7:0] NCUST8 = `MXQ_NCUSTOM;

    reg        irq_en;
    reg  [1:0] irq_stat;
    reg        halted_q;

    wire wr = acc & we;
    wire done_edge = halted & ~halted_q;

    assign irq = irq_en & (|irq_stat);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start <= 1'b0; soft_rst <= 1'b0; irq_en <= 1'b0;
            irq_stat <= 2'd0; halted_q <= 1'b0;
            start_pc <= 32'd0; wdog <= 32'd0;
            arg0 <= 32'd0; arg1 <= 32'd0; arg2 <= 32'd0; arg3 <= 32'd0;
        end else begin
            start    <= 1'b0;
            soft_rst <= 1'b0;
            halted_q <= halted;

            // the core reaching a halt raises exactly one of the two flags
            if (done_edge) begin
                if (trapped) irq_stat[`MXQ_IRQ_TRAP] <= 1'b1;
                else         irq_stat[`MXQ_IRQ_DONE] <= 1'b1;
            end

            if (wr) begin
                case (raddr)
                    `MXQ_R_CTRL: begin
                        irq_en <= wdata[`MXQ_CTRL_IRQ_EN];
                        if (wdata[`MXQ_CTRL_START] & ~running) start <= 1'b1;
                        if (wdata[`MXQ_CTRL_SOFT_RST]) begin
                            soft_rst <= 1'b1;
                            irq_stat <= 2'd0;
                            halted_q <= 1'b0;
                        end
                        if (wdata[`MXQ_CTRL_CLR_STAT]) irq_stat <= 2'd0;
                    end
                    `MXQ_R_IRQ_STAT: begin
                        if (wdata[`MXQ_IRQ_DONE]) irq_stat[`MXQ_IRQ_DONE] <= 1'b0;
                        if (wdata[`MXQ_IRQ_TRAP]) irq_stat[`MXQ_IRQ_TRAP] <= 1'b0;
                    end
                    `MXQ_R_START_PC: start_pc <= wdata;
                    `MXQ_R_WDOG:     wdog     <= wdata;
                    `MXQ_R_ARG0:     arg0     <= wdata;
                    `MXQ_R_ARG1:     arg1     <= wdata;
                    `MXQ_R_ARG2:     arg2     <= wdata;
                    `MXQ_R_ARG3:     arg3     <= wdata;
                    default: ;
                endcase
            end
        end
    end

    always @* begin
        case (raddr)
            `MXQ_R_CTRL:         rdata = {30'd0, irq_en, 1'b0};
            `MXQ_R_STATUS:       rdata = {29'd0, trapped, halted, running};
            `MXQ_R_IRQ_STAT:     rdata = {30'd0, irq_stat};
            `MXQ_R_ERRCODE:      rdata = {28'd0, errcode};
            `MXQ_R_START_PC:     rdata = start_pc;
            `MXQ_R_WDOG:         rdata = wdog;
            `MXQ_R_CYCLES:       rdata = c_cycles;
            `MXQ_R_INSTRET:      rdata = c_instret;
            `MXQ_R_CUSTOM_OPS:   rdata = c_custom;
            `MXQ_R_BRANCH_TAKEN: rdata = c_branch;
            `MXQ_R_LOADS:        rdata = c_loads;
            `MXQ_R_STORES:       rdata = c_stores;
            `MXQ_R_TRAP_PC:      rdata = trap_pc;
            `MXQ_R_ARG0:         rdata = arg0;
            `MXQ_R_ARG1:         rdata = arg1;
            `MXQ_R_ARG2:         rdata = arg2;
            `MXQ_R_ARG3:         rdata = arg3;
            `MXQ_R_RETVAL:       rdata = retval;
            `MXQ_R_HALT_PC:      rdata = halt_pc;
            `MXQ_R_CAPS:         rdata = {8'd0, NCUST8, DW8, IW8};
            `MXQ_R_VERSION:      rdata = `MXQ_VERSION_ID;
            `MXQ_R_REGMAP_CSUM:  rdata = `MXQ_REGMAP_CSUM;
            default:             rdata = 32'd0;
        endcase
    end
endmodule
