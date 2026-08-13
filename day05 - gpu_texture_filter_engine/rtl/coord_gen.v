// -----------------------------------------------------------------------------
// coord_gen.v
// Fixed-point coordinate resolver for one axis of the bilinear sampler.
//
// Given a Q16.16 sample position `acc` (accumulated as ox*scale, no multiply on
// the hot path) and the source dimension `dim`, it produces the two integer
// neighbour indices (clamp-to-edge) and the 8-bit fractional blend weight. It is
// purely combinational: instantiated once for x and once for y, its outputs feed
// the line buffer (indices) and the blend datapath (weights) in the same cycle.
//
// This is the hardware twin of the index/weight math in sw/tex_accel.h; the two
// are kept bit-identical so the differential test can require zero mismatches.
// -----------------------------------------------------------------------------
`default_nettype none

module coord_gen #(
    parameter integer IDXW = 16   // index width (pixels per axis)
)(
    input  wire [31:0]      acc,   // Q16.16 sample position
    input  wire [IDXW-1:0]  dim,   // source extent along this axis (pixels)
    output wire [IDXW-1:0]  i0,    // floor index, clamped to [0, dim-1]
    output wire [IDXW-1:0]  i1,    // i0+1, clamped to [0, dim-1]
    output wire [7:0]       frac   // 8-bit fractional weight (0..255)
);
    wire [IDXW-1:0] last = dim - 1'b1;
    wire [31:0]     raw  = acc >> 16;                 // integer part (>= 0)
    wire [IDXW-1:0] rawi = raw[IDXW-1:0];

    // clamp-to-edge: floor index and its right/bottom neighbour
    assign i0   = (raw > {16'b0, last}) ? last : rawi;
    assign i1   = ((i0 + 1'b1) > last) ? last : (i0 + 1'b1);
    assign frac = acc[15:8];                          // top 8 bits of fraction
endmodule

`default_nettype wire
