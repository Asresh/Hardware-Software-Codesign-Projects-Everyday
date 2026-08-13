// -----------------------------------------------------------------------------
// tex_top.v
// GPU-style bilinear texture-filter / image-resampler top level. Ties together:
//
//   tex_regfile     - mailbox + doorbell + completion interrupt (control plane)
//   tex_ctrl        - sequencer + wide memory master (data movement + timing)
//   line_buffer     - the two resident source rows (line-buffer window)
//   coord_gen (x,y) - fixed-point neighbour/weight resolvers
//   bilinear_blend  - the four-texel filter datapath
//
// The datapath is deliberately flat: the x/y accumulators live in the sequencer,
// the coord_gen units turn them into neighbour indices and weights, the line
// buffer returns the 2x2 texel gather, and the blend unit produces one filtered
// pixel per clock which the sequencer packs and stores.
// -----------------------------------------------------------------------------
`default_nettype none

module tex_top #(
    parameter integer PIX_W      = 8,
    parameter integer PPW        = 4,
    parameter integer ADDR_WIDTH = 20,
    parameter integer WMAX       = 64,
    parameter integer IDXW       = 16,
    parameter integer WORD_W     = PPW*PIX_W,
    parameter [31:0]  IDENT_VALUE = 32'h5B170005
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- MMIO mailbox ----
    input  wire                   mmio_sel,
    input  wire                   mmio_write,
    input  wire [7:0]             mmio_addr,
    input  wire [31:0]            mmio_wdata,
    output wire [31:0]            mmio_rdata,

    // ---- wide memory master ----
    output wire                   mem_rd_en,
    output wire [ADDR_WIDTH-1:0]  mem_rd_addr,
    input  wire [WORD_W-1:0]      mem_rd_data,
    output wire                   mem_wr_en,
    output wire [ADDR_WIDTH-1:0]  mem_wr_addr,
    output wire [WORD_W-1:0]      mem_wr_data,

    output wire                   irq
);
    // ---- descriptor / status between regfile and sequencer ----
    wire                   start;
    wire [ADDR_WIDTH-1:0]  src_base, dst_base;
    wire [15:0]            src_w, src_h, dst_w, dst_h;
    wire [31:0]            scale_x, scale_y;
    wire                   busy, done_set;
    wire [31:0]            cycles;

    // ---- datapath wires ----
    wire [31:0]      ux, uy;
    wire [IDXW-1:0]  x0, x1, y0, y1;
    wire [7:0]       fx, fy;
    wire [PIX_W-1:0] p00, p01, p10, p11, out_pix;

    // ---- line-buffer write port ----
    wire                lb_wr_en, lb_wr_row;
    wire [IDXW-1:0]     lb_wr_word;
    wire [WORD_W-1:0]   lb_wr_data;

    // ---------------- control plane ----------------
    tex_regfile #(
        .ADDR_WIDTH(ADDR_WIDTH), .IDENT_VALUE(IDENT_VALUE)
    ) u_regs (
        .clk(clk), .rst_n(rst_n),
        .mmio_sel(mmio_sel), .mmio_write(mmio_write), .mmio_addr(mmio_addr),
        .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .start(start), .src_base(src_base), .dst_base(dst_base),
        .src_w(src_w), .src_h(src_h), .dst_w(dst_w), .dst_h(dst_h),
        .scale_x(scale_x), .scale_y(scale_y),
        .busy(busy), .done_set(done_set), .cycles(cycles), .irq(irq)
    );

    // ---------------- sequencer + memory master ----------------
    tex_ctrl #(
        .PIX_W(PIX_W), .PPW(PPW), .WORD_W(WORD_W),
        .ADDR_WIDTH(ADDR_WIDTH), .IDXW(IDXW)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .start(start), .src_base(src_base), .dst_base(dst_base),
        .src_w(src_w), .src_h(src_h), .dst_w(dst_w), .dst_h(dst_h),
        .scale_x(scale_x), .scale_y(scale_y),
        .ux(ux), .uy(uy), .y0(y0), .y1(y1), .out_pix(out_pix),
        .lb_wr_en(lb_wr_en), .lb_wr_row(lb_wr_row),
        .lb_wr_word(lb_wr_word), .lb_wr_data(lb_wr_data),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_data(mem_rd_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
        .busy(busy), .done_set(done_set), .cycles(cycles)
    );

    // ---------------- coordinate resolvers ----------------
    coord_gen #(.IDXW(IDXW)) u_cx (
        .acc(ux), .dim(src_w[IDXW-1:0]), .i0(x0), .i1(x1), .frac(fx)
    );
    coord_gen #(.IDXW(IDXW)) u_cy (
        .acc(uy), .dim(src_h[IDXW-1:0]), .i0(y0), .i1(y1), .frac(fy)
    );

    // ---------------- line-buffer window ----------------
    line_buffer #(
        .PIX_W(PIX_W), .PPW(PPW), .WMAX(WMAX), .IDXW(IDXW), .WORD_W(WORD_W)
    ) u_lb (
        .clk(clk),
        .wr_en(lb_wr_en), .wr_row(lb_wr_row),
        .wr_word(lb_wr_word), .wr_data(lb_wr_data),
        .x0(x0), .x1(x1), .p00(p00), .p01(p01), .p10(p10), .p11(p11)
    );

    // ---------------- blend datapath ----------------
    bilinear_blend #(.PIX_W(PIX_W)) u_blend (
        .p00(p00), .p01(p01), .p10(p10), .p11(p11),
        .fx(fx), .fy(fy), .pout(out_pix)
    );
endmodule

`default_nettype wire
