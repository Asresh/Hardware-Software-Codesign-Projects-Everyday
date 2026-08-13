// -----------------------------------------------------------------------------
// bilinear_blend.v
// The fixed-function texel-blend datapath: four neighbouring texels and the two
// 8-bit fractional weights in, one filtered pixel out. This is the arithmetic a
// GPU texture unit performs per bilinear sample.
//
//   top = p00*(256-fx) + p01*fx        (horizontal lerp on the top row)
//   bot = p10*(256-fx) + p11*fx        (horizontal lerp on the bottom row)
//   out = (top*(256-fy) + bot*fy) >> 16 (vertical lerp, back to 8 bits)
//
// Weights sum to 256, so each horizontal lerp is bounded by 255*256 and the
// final numerator by 255*65536; the >>16 returns an exact 8-bit result. All
// integer, and bit-identical to tex_bilinear() in sw/tex_accel.h. Combinational
// here for clarity; the multiplies would be registered for timing in silicon.
// -----------------------------------------------------------------------------
`default_nettype none

module bilinear_blend #(
    parameter integer PIX_W = 8
)(
    input  wire [PIX_W-1:0] p00,   // top-left texel
    input  wire [PIX_W-1:0] p01,   // top-right texel
    input  wire [PIX_W-1:0] p10,   // bottom-left texel
    input  wire [PIX_W-1:0] p11,   // bottom-right texel
    input  wire [7:0]       fx,    // horizontal fractional weight (0..255)
    input  wire [7:0]       fy,    // vertical fractional weight   (0..255)
    output wire [PIX_W-1:0] pout   // filtered pixel
);
    wire [8:0] ifx = 9'd256 - {1'b0, fx};   // 256-fx  (1..256)
    wire [8:0] ify = 9'd256 - {1'b0, fy};

    // horizontal lerps, each <= 255*256 = 65280  (17 bits)
    wire [17:0] top = p00 * ifx + p01 * {1'b0, fx};
    wire [17:0] bot = p10 * ifx + p11 * {1'b0, fx};

    // vertical lerp: numerator <= 65280*256  (25 bits), >>16 -> 8 bits
    wire [25:0] num = top * ify + bot * {1'b0, fy};

    assign pout = num[PIX_W-1+16:16];
endmodule

`default_nettype wire
