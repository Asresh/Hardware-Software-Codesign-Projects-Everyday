// -----------------------------------------------------------------------------
// sort_top.v
// Top level of the GPU-style tiled bitonic sort accelerator.
//
//   * MMIO control plane: a single-cycle memory-mapped register file. The host
//     programs the descriptor CSRs, pulses START, and either polls STATUS or
//     waits on the completion interrupt.
//   * sort_ctrl: descriptor-driven controller + coalesced wide-DMA master.
//   * bitonic_network + compare_exchange: the pipelined Batcher sorting network
//     that retires one sorted N-key tile per clock.
//   * A wide (N*W-bit) memory master port to external/device memory - one beat
//     is exactly one tile, modelling GPU memory coalescing.
//   * A maskable, clearable completion interrupt.
//
// Register map (byte offset from the MMIO base):
//   0x00 IDENT  R   32'h5B17_0004  (BITONIC sort, day 4)
//   0x04 CTRL   W   [0]=START [1]=IRQ_EN [2]=IRQ_CLR
//   0x08 STATUS R   [0]=DONE  [1]=BUSY   [2]=IRQ
//   0x0C SRC    RW  source base word address
//   0x10 DST    RW  destination base word address
//   0x14 NTILES RW  number of N-key tiles to sort
//   0x18 MODE   RW  [0]=1 descending, 0 ascending
//   0x1C CYCLES R   measured START->DONE latency of the last job
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module sort_top #(
    parameter integer N          = 16,   // keys per tile (power of two)
    parameter integer W          = 32,   // key width
    parameter integer ADDR_WIDTH = 20,   // word address space
    parameter integer TILE_WIDTH = 16    // max tile-count width
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- MMIO control plane (single-cycle register bus) ----
    input  wire                  mmio_sel,     // access this cycle
    input  wire                  mmio_write,   // 1 = write, 0 = read
    input  wire [7:0]            mmio_addr,    // byte offset
    input  wire [31:0]           mmio_wdata,
    output reg  [31:0]           mmio_rdata,

    // ---- wide (coalesced) memory master ----
    output wire                  mem_rd_en,
    output wire [ADDR_WIDTH-1:0] mem_rd_addr,
    input  wire [N*W-1:0]        mem_rd_data,  // valid 1 cycle after mem_rd_en
    output wire                  mem_wr_en,
    output wire [ADDR_WIDTH-1:0] mem_wr_addr,
    output wire [N*W-1:0]        mem_wr_data,

    // ---- completion interrupt ----
    output wire                  irq
);
    localparam [31:0] IDENT_VALUE = 32'h5B17_0004;

    // CSR word-index (byte offset >> 2)
    localparam [5:0] A_IDENT = 6'h00, A_CTRL   = 6'h01, A_STATUS = 6'h02,
                     A_SRC   = 6'h03, A_DST    = 6'h04, A_NTILES = 6'h05,
                     A_MODE  = 6'h06, A_CYCLES = 6'h07;

    wire [5:0] widx = mmio_addr[7:2];

    // ---- descriptor registers ----
    reg [ADDR_WIDTH-1:0] src_reg, dst_reg;
    reg [TILE_WIDTH-1:0] ntiles_reg;
    reg                  mode_reg;
    reg                  irq_en;

    // ---- MMIO access strobes ----
    wire wr_commit   = mmio_sel & mmio_write;         // single-cycle write
    wire start_pulse = wr_commit & (widx == A_CTRL) & mmio_wdata[0];
    wire irq_clr     = wr_commit & (widx == A_CTRL) & mmio_wdata[2];

    // ---- controller status ----
    wire        busy, done;
    wire [31:0] cycles;

    // ---- interrupt: latch on rising DONE when enabled, clear on IRQ_CLR ----
    reg done_d, irq_pending;
    assign irq = irq_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src_reg     <= {ADDR_WIDTH{1'b0}};
            dst_reg     <= {ADDR_WIDTH{1'b0}};
            ntiles_reg  <= {TILE_WIDTH{1'b0}};
            mode_reg    <= 1'b0;
            irq_en      <= 1'b0;
            done_d      <= 1'b0;
            irq_pending <= 1'b0;
        end else begin
            done_d <= done;

            if (wr_commit) begin
                case (widx)
                    A_CTRL:   irq_en     <= mmio_wdata[1];
                    A_SRC:    src_reg    <= mmio_wdata[ADDR_WIDTH-1:0];
                    A_DST:    dst_reg    <= mmio_wdata[ADDR_WIDTH-1:0];
                    A_NTILES: ntiles_reg <= mmio_wdata[TILE_WIDTH-1:0];
                    A_MODE:   mode_reg   <= mmio_wdata[0];
                    default: ;
                endcase
            end

            if (done & ~done_d & irq_en)
                irq_pending <= 1'b1;
            if (irq_clr)
                irq_pending <= 1'b0;
        end
    end

    // ---- MMIO read mux (combinational) ----
    always @(*) begin
        case (widx)
            A_IDENT:  mmio_rdata = IDENT_VALUE;
            A_CTRL:   mmio_rdata = {29'd0, irq_en, 1'b0, 1'b0};
            A_STATUS: mmio_rdata = {29'd0, irq_pending, busy, done};
            A_SRC:    mmio_rdata = {{(32-ADDR_WIDTH){1'b0}}, src_reg};
            A_DST:    mmio_rdata = {{(32-ADDR_WIDTH){1'b0}}, dst_reg};
            A_NTILES: mmio_rdata = {{(32-TILE_WIDTH){1'b0}}, ntiles_reg};
            A_MODE:   mmio_rdata = {31'd0, mode_reg};
            A_CYCLES: mmio_rdata = cycles;
            default:  mmio_rdata = 32'd0;
        endcase
    end

    // ---- controller <-> network nets ----
    wire               dp_in_valid, dp_in_desc, dp_out_valid;
    wire [N*W-1:0]     dp_in_data,  dp_out_data;

    sort_ctrl #(
        .N(N), .W(W), .ADDR_WIDTH(ADDR_WIDTH), .TILE_WIDTH(TILE_WIDTH)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .start(start_pulse), .src_addr(src_reg), .dst_addr(dst_reg),
        .ntiles(ntiles_reg), .mode_desc(mode_reg),
        .busy(busy), .done(done), .cycles(cycles),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_data(mem_rd_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
        .dp_in_valid(dp_in_valid), .dp_in_desc(dp_in_desc), .dp_in_data(dp_in_data),
        .dp_out_valid(dp_out_valid), .dp_out_data(dp_out_data)
    );

    bitonic_network #(
        .N(N), .W(W)
    ) u_net (
        .clk(clk), .rst_n(rst_n),
        .in_valid(dp_in_valid), .in_desc(dp_in_desc), .in_data(dp_in_data),
        .out_valid(dp_out_valid), .out_data(dp_out_data)
    );
endmodule

`default_nettype wire
