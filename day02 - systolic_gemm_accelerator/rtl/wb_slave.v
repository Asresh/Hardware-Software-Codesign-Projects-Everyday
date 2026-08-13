// -----------------------------------------------------------------------------
// wb_slave.v
// Wishbone B4 classic-cycle slave forming the control plane of the GEMM engine.
// It exposes the control/status registers and decodes the three memory windows
// (operand A, operand B, result C). It is a single-outstanding slave that
// acknowledges one transfer per (CYC & STB) with a registered ACK.
//
// Byte-address map (ADDR_WIDTH bits, 32-bit registers/words):
//   region = adr[15:12]
//     0x0 control block      adr[7:2] selects the register
//         0x00 CTRL   W  [0]=START(self-clearing) [1]=IRQ_EN [2]=IRQ_CLR
//         0x04 STATUS R  [0]=DONE [1]=BUSY
//         0x08 KLEN   RW inner dimension K for the next run (1..KMAX)
//         0x0C MODE   RW [0]=ACCUM (0=clear C then compute, 1=accumulate)
//         0x10 N_DIM  R  compile-time array dimension N
//         0x14 DATA_W R  compile-time operand width
//         0x18 KMAXR  R  compile-time KMAX
//         0x1C CYCLES R  START->DONE cycle count of the last run
//     0x1 A window   adr[8:2] = word index into operand-A buffer (A^T, col-major)
//     0x2 B window   adr[8:2] = word index into operand-B buffer (row-major)
//     0x3 C window   adr[7:2] = word index into result C (C[i][j] at i*N+j)
//
// The buffers and the result accumulators live in gemm_top; this slave only
// produces the decoded write strobes / read address and multiplexes read data.
// -----------------------------------------------------------------------------
`default_nettype none

module wb_slave #(
    parameter integer N          = 8,
    parameter integer DATA_WIDTH = 8,
    parameter integer KMAX       = 64,
    parameter integer ADDR_WIDTH = 16,
    parameter integer KW         = $clog2(KMAX + 1)
) (
    input  wire                    clk_i,
    input  wire                    rst_i,        // Wishbone: active high

    // ---- Wishbone B4 classic slave ----
    input  wire [ADDR_WIDTH-1:0]   wb_adr_i,
    input  wire [31:0]             wb_dat_i,
    output reg  [31:0]             wb_dat_o,
    input  wire [3:0]              wb_sel_i,
    input  wire                    wb_we_i,
    input  wire                    wb_stb_i,
    input  wire                    wb_cyc_i,
    output reg                     wb_ack_o,

    // ---- decoded control to the core ----
    output wire [KW-1:0]           klen,
    output wire                    accum_mode,
    output wire                    irq_en,
    output wire                    start_pulse,
    output wire                    irq_clr_pulse,

    // ---- status / telemetry from the core ----
    input  wire                    done,
    input  wire                    busy,
    input  wire [31:0]             cycles,

    // ---- operand buffer write port (to gemm_top) ----
    output wire                    a_we,
    output wire                    b_we,
    output wire [6:0]              buf_waddr,   // word index, 0..(2*KMAX*N/8-1)
    output wire [31:0]             buf_wdata,
    output wire [3:0]              buf_sel,

    // ---- result read port (from gemm_top) ----
    output wire [$clog2(N*N)-1:0]  c_raddr,     // word index, 0..N*N-1
    input  wire [31:0]             c_rdata
);
    // ---- control-block register offsets (word index adr[7:2]) ----
    localparam [5:0] R_CTRL=6'h0, R_STATUS=6'h1, R_KLEN=6'h2, R_MODE=6'h3,
                     R_NDIM=6'h4, R_DATAW=6'h5, R_KMAX=6'h6, R_CYCLES=6'h7;

    // ---- registered single-cycle ACK ----
    always @(posedge clk_i) begin
        if (rst_i) wb_ack_o <= 1'b0;
        else       wb_ack_o <= wb_cyc_i & wb_stb_i & ~wb_ack_o;
    end

    wire        active   = wb_cyc_i & wb_stb_i & ~wb_ack_o;   // the transfer cycle
    wire        wr_fire  = active &  wb_we_i;
    wire [3:0]  region   = wb_adr_i[15:12];
    wire [5:0]  reg_sel  = wb_adr_i[7:2];

    localparam [3:0] REG_A = 4'h1, REG_B = 4'h2, REG_C = 4'h3, REG_CTL = 4'h0;

    // ---- configuration registers ----
    reg [KW-1:0] klen_reg;
    reg          accum_reg;
    reg          irq_en_reg;

    always @(posedge clk_i) begin
        if (rst_i) begin
            klen_reg   <= {{(KW-1){1'b0}}, 1'b1};   // sane default K = 1
            accum_reg  <= 1'b0;
            irq_en_reg <= 1'b0;
        end else if (wr_fire && region == REG_CTL) begin
            case (reg_sel)
                R_CTRL: irq_en_reg <= wb_dat_i[1];
                R_KLEN: klen_reg   <= wb_dat_i[KW-1:0];
                R_MODE: accum_reg  <= wb_dat_i[0];
                default: ;
            endcase
        end
    end

    assign klen          = klen_reg;
    assign accum_mode    = accum_reg;
    assign irq_en        = irq_en_reg;
    assign start_pulse   = wr_fire && (region == REG_CTL) && (reg_sel == R_CTRL) && wb_dat_i[0];
    assign irq_clr_pulse = wr_fire && (region == REG_CTL) && (reg_sel == R_CTRL) && wb_dat_i[2];

    // ---- operand buffer writes ----
    assign a_we      = wr_fire && (region == REG_A);
    assign b_we      = wr_fire && (region == REG_B);
    assign buf_waddr = wb_adr_i[8:2];
    assign buf_wdata = wb_dat_i;
    assign buf_sel   = wb_sel_i;

    // ---- result reads ----
    assign c_raddr = wb_adr_i[$clog2(N*N)+1:2];

    // ---- read data multiplexer ----
    always @(*) begin
        case (region)
            REG_C:   wb_dat_o = c_rdata;
            REG_CTL: begin
                case (reg_sel)
                    R_CTRL:   wb_dat_o = {30'd0, irq_en_reg, 1'b0};
                    R_STATUS: wb_dat_o = {30'd0, busy, done};
                    R_KLEN:   wb_dat_o = {{(32-KW){1'b0}}, klen_reg};
                    R_MODE:   wb_dat_o = {31'd0, accum_reg};
                    R_NDIM:   wb_dat_o = N[31:0];
                    R_DATAW:  wb_dat_o = DATA_WIDTH[31:0];
                    R_KMAX:   wb_dat_o = KMAX[31:0];
                    R_CYCLES: wb_dat_o = cycles;
                    default:  wb_dat_o = 32'hDEAD_BEEF;
                endcase
            end
            default: wb_dat_o = 32'hDEAD_BEEF;
        endcase
    end
endmodule

`default_nettype wire
