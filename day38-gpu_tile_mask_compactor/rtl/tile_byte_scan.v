// Author: Asresh
`timescale 1ns/1ps
module tile_byte_scan(
  input  wire [63:0] mask,
  output wire [31:0] byte_counts,
  output wire [7:0]  byte_nonzero
);
  wire [3:0] c0,c1,c2,c3,c4,c5,c6,c7;
  tile_popcount8 u0(.bits(mask[7:0]),.count(c0));
  tile_popcount8 u1(.bits(mask[15:8]),.count(c1));
  tile_popcount8 u2(.bits(mask[23:16]),.count(c2));
  tile_popcount8 u3(.bits(mask[31:24]),.count(c3));
  tile_popcount8 u4(.bits(mask[39:32]),.count(c4));
  tile_popcount8 u5(.bits(mask[47:40]),.count(c5));
  tile_popcount8 u6(.bits(mask[55:48]),.count(c6));
  tile_popcount8 u7(.bits(mask[63:56]),.count(c7));
  assign byte_counts={c7,c6,c5,c4,c3,c2,c1,c0};
  assign byte_nonzero={|mask[63:56],|mask[55:48],|mask[47:40],|mask[39:32],
                       |mask[31:24],|mask[23:16],|mask[15:8],|mask[7:0]};
endmodule
