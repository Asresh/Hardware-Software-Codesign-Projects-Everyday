// ============================================================================
// arc_regfile.v - MMIO control/status register file for the collective engine.
//
// A simple single-cycle memory-mapped register bus (the host writes the
// descriptor-ring base/count and kicks the engine, then polls or takes the
// completion interrupt).  Combinational read, registered write.  done/err are
// sticky status bits set by the DMA engine and cleared write-1-to-clear; the
// interrupt is their OR, gated by irq_en.
// ============================================================================
`default_nettype none

module arc_regfile #(
    parameter integer R  = 4,
    parameter integer P  = 4,
    parameter integer DW = 32,
    parameter integer AW = 24
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- MMIO bus ----
    input  wire        reg_wr,
    input  wire        reg_rd,
    input  wire [7:0]  reg_addr,
    input  wire [31:0] reg_wdata,
    output reg  [31:0] reg_rdata,

    // ---- to DMA engine ----
    output reg         start,
    output reg         soft_reset,
    output reg         irq_en,
    output reg  [AW-1:0] desc_base,
    output reg  [15:0]   desc_count,

    // ---- from DMA engine ----
    input  wire        busy,
    input  wire        done_pulse,
    input  wire        err_pulse,
    input  wire [7:0]  errcode,
    input  wire [31:0] completed,
    input  wire [31:0] groups_total,
    input  wire [31:0] words_total,

    // ---- interrupt ----
    output wire        irq
);
    localparam [7:0]
        REG_CTRL_A = 8'h00, REG_STATUS_A = 8'h04, REG_DBASE_A = 8'h08,
        REG_DCNT_A = 8'h0C, REG_COMPL_A  = 8'h10, REG_GRPS_A  = 8'h14,
        REG_WORDS_A= 8'h18, REG_SCR_A    = 8'h1C, REG_PARM_A  = 8'h20,
        REG_VER_A  = 8'h24, REG_ERR_A    = 8'h28;

    reg        done_sticky, err_sticky;
    reg [31:0] scratch;

    assign irq = irq_en & (done_sticky | err_sticky);

    always @(posedge clk) begin
        if (!rst_n) begin
            start <= 0; soft_reset <= 0; irq_en <= 0;
            desc_base <= 0; desc_count <= 0; scratch <= 0;
            done_sticky <= 0; err_sticky <= 0;
        end else begin
            start <= 0; soft_reset <= 0;          // one-cycle pulses

            // sticky status set by the engine
            if (done_pulse) done_sticky <= 1;
            if (err_pulse)  err_sticky  <= 1;

            if (reg_wr) begin
                case (reg_addr)
                    REG_CTRL_A: begin
                        start      <= reg_wdata[0];
                        soft_reset <= reg_wdata[1];
                        irq_en     <= reg_wdata[2];
                        if (reg_wdata[1]) begin        // soft-reset also clears sticky
                            done_sticky <= 1'b0;
                            err_sticky  <= 1'b0;
                        end
                    end
                    REG_STATUS_A: begin              // W1C
                        if (reg_wdata[0]) done_sticky <= 1'b0;
                        if (reg_wdata[1]) err_sticky  <= 1'b0;
                    end
                    REG_DBASE_A: desc_base  <= reg_wdata[AW-1:0];
                    REG_DCNT_A:  desc_count <= reg_wdata[15:0];
                    REG_SCR_A:   scratch    <= reg_wdata;
                    default: ;
                endcase
            end
        end
    end

    always @* begin
        reg_rdata = 32'd0;
        if (reg_rd) begin
            case (reg_addr)
                REG_CTRL_A:   reg_rdata = {29'd0, irq_en, 1'b0, 1'b0};
                REG_STATUS_A: reg_rdata = {29'd0, busy, err_sticky, done_sticky};
                REG_DBASE_A:  reg_rdata = {{(32-AW){1'b0}}, desc_base};
                REG_DCNT_A:   reg_rdata = {16'd0, desc_count};
                REG_COMPL_A:  reg_rdata = completed;
                REG_GRPS_A:   reg_rdata = groups_total;
                REG_WORDS_A:  reg_rdata = words_total;
                REG_SCR_A:    reg_rdata = scratch;
                REG_PARM_A:   reg_rdata = (DW << 16) | (P << 8) | R;
                REG_VER_A:    reg_rdata = 32'hFEED_000E;
                REG_ERR_A:    reg_rdata = {24'd0, errcode};
                default:      reg_rdata = 32'd0;
            endcase
        end
    end
endmodule

`default_nettype wire
