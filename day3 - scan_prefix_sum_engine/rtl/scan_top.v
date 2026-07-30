// -----------------------------------------------------------------------------
// scan_top.v
// Top level of the GPU-style parallel prefix-sum (scan) engine.
//
//   * APB control plane (PSEL/PENABLE/PWRITE/PADDR/PWDATA/PRDATA/PREADY): the
//     host programs the descriptor CSRs, pulses START, and either polls STATUS
//     or waits on the completion interrupt.
//   * dma_desc: descriptor-driven controller + coalesced wide-DMA master.
//   * scan_datapath + prefix_tree: the LANES-wide work parallel-prefix tree.
//   * A wide (LANES*W-bit) memory master port to external/device memory.
//   * A level completion interrupt, maskable and clearable through CTRL.
//
// Register map (byte offset from APB base):
//   0x00 IDENT  R   32'h5CA4_0003  (SCAN, day 3)
//   0x04 CTRL   W   [0]=START [1]=IRQ_EN [2]=IRQ_CLR
//   0x08 STATUS R   [0]=DONE  [1]=BUSY   [2]=IRQ
//   0x0C SRC    RW  source base word address
//   0x10 DST    RW  destination base word address
//   0x14 LEN    RW  element count
//   0x18 MODE   RW  [0]=1 exclusive scan, 0 inclusive scan
//   0x1C CYCLES R   measured START->DONE latency of the last job
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module scan_top #(
    parameter integer LANES      = 16,   // words per coalesced beat (power of two)
    parameter integer W          = 32,   // word width
    parameter integer ADDR_WIDTH = 20,   // word address space
    parameter integer LEN_WIDTH  = 20    // max element count width
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- APB control plane ----
    input  wire                  psel,
    input  wire                  penable,
    input  wire                  pwrite,
    input  wire [7:0]            paddr,
    input  wire [31:0]           pwdata,
    output reg  [31:0]           prdata,
    output wire                  pready,

    // ---- wide (coalesced) memory master ----
    output wire                  mem_rd_en,
    output wire [ADDR_WIDTH-1:0] mem_rd_addr,
    input  wire [LANES*W-1:0]    mem_rd_data,
    output wire                  mem_wr_en,
    output wire [ADDR_WIDTH-1:0] mem_wr_addr,
    output wire [LANES*W-1:0]    mem_wr_data,
    output wire [LANES-1:0]      mem_wr_be,     // per-word write enable (short tile)

    // ---- completion interrupt ----
    output wire                  irq
);
    function integer clog2;
        input integer value; integer i;
        begin clog2 = 0; for (i = value-1; i > 0; i = i >> 1) clog2 = clog2 + 1; end
    endfunction
    localparam integer LANE_BITS = clog2(LANES) + 1;   // holds 0..LANES

    localparam [31:0] IDENT_VALUE = 32'h5CA4_0003;

    // CSR word-index (byte offset >> 2)
    localparam [5:0] A_IDENT  = 6'h00, A_CTRL  = 6'h01, A_STATUS = 6'h02,
                     A_SRC    = 6'h03, A_DST   = 6'h04, A_LEN    = 6'h05,
                     A_MODE   = 6'h06, A_CYCLES= 6'h07;

    wire [5:0] widx = paddr[7:2];

    // ---- descriptor registers ----
    reg [ADDR_WIDTH-1:0] src_reg, dst_reg;
    reg [LEN_WIDTH-1:0]  len_reg;
    reg                  mode_reg;
    reg                  irq_en;

    // ---- APB access strobes ----
    assign pready      = 1'b1;                       // zero-wait-state slave
    wire   wr_commit   = psel & penable & pwrite;    // 1-cycle write in ACCESS
    wire   start_pulse = wr_commit & (widx == A_CTRL) & pwdata[0];
    wire   irq_clr     = wr_commit & (widx == A_CTRL) & pwdata[2];

    // ---- controller / datapath status ----
    wire        busy, done;
    wire [31:0] cycles;

    // ---- interrupt: latch on rising DONE when enabled, clear on IRQ_CLR ----
    reg  done_d, irq_pending;
    assign irq = irq_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src_reg     <= {ADDR_WIDTH{1'b0}};
            dst_reg     <= {ADDR_WIDTH{1'b0}};
            len_reg     <= {LEN_WIDTH{1'b0}};
            mode_reg    <= 1'b0;
            irq_en      <= 1'b0;
            done_d      <= 1'b0;
            irq_pending <= 1'b0;
        end else begin
            done_d <= done;

            if (wr_commit) begin
                case (widx)
                    A_CTRL: irq_en <= pwdata[1];
                    A_SRC:  src_reg  <= pwdata[ADDR_WIDTH-1:0];
                    A_DST:  dst_reg  <= pwdata[ADDR_WIDTH-1:0];
                    A_LEN:  len_reg  <= pwdata[LEN_WIDTH-1:0];
                    A_MODE: mode_reg <= pwdata[0];
                    default: ;
                endcase
            end

            if (done & ~done_d & irq_en)
                irq_pending <= 1'b1;
            if (irq_clr)
                irq_pending <= 1'b0;
        end
    end

    // ---- APB read mux (combinational) ----
    always @(*) begin
        case (widx)
            A_IDENT:  prdata = IDENT_VALUE;
            A_CTRL:   prdata = {29'd0, irq_en, 1'b0, 1'b0};
            A_STATUS: prdata = {29'd0, irq_pending, busy, done};
            A_SRC:    prdata = {{(32-ADDR_WIDTH){1'b0}}, src_reg};
            A_DST:    prdata = {{(32-ADDR_WIDTH){1'b0}}, dst_reg};
            A_LEN:    prdata = {{(32-LEN_WIDTH){1'b0}},  len_reg};
            A_MODE:   prdata = {31'd0, mode_reg};
            A_CYCLES: prdata = cycles;
            default:  prdata = 32'd0;
        endcase
    end

    // ---- datapath <-> controller nets ----
    wire                 clr_carry, dp_mode_excl;
    wire                 dp_in_valid, dp_out_valid;
    wire [LANES*W-1:0]   dp_in_data,  dp_out_data;
    wire [LANE_BITS-1:0] dp_in_lanes, dp_out_lanes;
    wire [LANE_BITS-1:0] wr_lanes;

    dma_desc #(
        .LANES(LANES), .W(W), .ADDR_WIDTH(ADDR_WIDTH),
        .LEN_WIDTH(LEN_WIDTH), .LANE_BITS(LANE_BITS)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .start(start_pulse), .src_addr(src_reg), .dst_addr(dst_reg),
        .len(len_reg), .mode_excl(mode_reg),
        .busy(busy), .done(done), .cycles(cycles),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_data(mem_rd_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr),
        .mem_wr_lanes(wr_lanes), .mem_wr_data(mem_wr_data),
        .clr_carry(clr_carry), .dp_mode_excl(dp_mode_excl),
        .dp_in_valid(dp_in_valid), .dp_in_data(dp_in_data), .dp_in_lanes(dp_in_lanes),
        .dp_out_valid(dp_out_valid), .dp_out_data(dp_out_data), .dp_out_lanes(dp_out_lanes)
    );

    scan_datapath #(
        .LANES(LANES), .W(W), .LANE_BITS(LANE_BITS)
    ) u_dp (
        .clk(clk), .rst_n(rst_n),
        .clr_carry(clr_carry), .mode_excl(dp_mode_excl),
        .in_valid(dp_in_valid), .in_data(dp_in_data), .in_lanes(dp_in_lanes),
        .out_valid(dp_out_valid), .out_data(dp_out_data), .out_lanes(dp_out_lanes)
    );

    // ---- expand valid-lane count into a per-word write-enable mask ----
    genvar b;
    generate
        for (b = 0; b < LANES; b = b + 1) begin : g_be
            assign mem_wr_be[b] = mem_wr_en & (b < wr_lanes);
        end
    endgenerate
endmodule

`default_nettype wire
