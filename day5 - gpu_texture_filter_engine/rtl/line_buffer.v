// -----------------------------------------------------------------------------
// line_buffer.v
// The two on-chip source rows the sampler is currently working between - the
// heart of the line-buffer microarchitecture. Bilinear filtering of output row
// oy needs source rows y0 and y0+1; because y0 advances monotonically as the
// engine walks down the image, only these two rows ever need to be resident, so
// the whole source image is streamed past a two-row window instead of being
// buffered in full. When consecutive output rows map to the same source pair
// (the common case when magnifying) the rows are reused with no refetch at all.
//
// Each row is a byte array (WMAX pixels) filled a memory word (PPW pixels) at a
// time by the loader, and read as a 2x2 texel neighbourhood combinationally:
// p00,p01 from the top row at columns x0,x1 and p10,p11 from the bottom row. The
// four asynchronous byte reads are what let the blend datapath retire one
// filtered pixel per clock.
// -----------------------------------------------------------------------------
`default_nettype none

module line_buffer #(
    parameter integer PIX_W = 8,
    parameter integer PPW   = 4,     // pixels per memory word
    parameter integer WMAX  = 64,    // max row width in pixels
    parameter integer IDXW  = 16,
    parameter integer WORD_W = PPW*PIX_W
)(
    input  wire                 clk,
    // write port: one memory word (PPW pixels) into a row
    input  wire                 wr_en,
    input  wire                 wr_row,        // 0 = top row, 1 = bottom row
    input  wire [IDXW-1:0]      wr_word,       // word index within the row
    input  wire [WORD_W-1:0]    wr_data,
    // read port: 2x2 texel neighbourhood
    input  wire [IDXW-1:0]      x0,
    input  wire [IDXW-1:0]      x1,
    output wire [PIX_W-1:0]     p00,           // top[x0]
    output wire [PIX_W-1:0]     p01,           // top[x1]
    output wire [PIX_W-1:0]     p10,           // bot[x0]
    output wire [PIX_W-1:0]     p11            // bot[x1]
);
    reg [PIX_W-1:0] top [0:WMAX-1];
    reg [PIX_W-1:0] bot [0:WMAX-1];

    integer k;
    // synthesis note: a word write updates PPW adjacent byte lanes
    always @(posedge clk) begin
        if (wr_en) begin
            for (k = 0; k < PPW; k = k + 1) begin
                if (wr_row == 1'b0)
                    top[wr_word*PPW + k] <= wr_data[k*PIX_W +: PIX_W];
                else
                    bot[wr_word*PPW + k] <= wr_data[k*PIX_W +: PIX_W];
            end
        end
    end

    assign p00 = top[x0];
    assign p01 = top[x1];
    assign p10 = bot[x0];
    assign p11 = bot[x1];
endmodule

`default_nettype wire
