// Author: Asresh
`timescale 1ns/1ps
module tile_mask_reduce(
  input  wire [63:0] mask,
  input  wire [31:0] byte_counts,
  input  wire [7:0]  byte_nonzero,
  output reg  [6:0]  active_count,
  output reg  [5:0]  first_active,
  output reg  [5:0]  last_active,
  output wire        empty
);
  integer i;
  reg first_seen;
  always @* begin
    active_count = 7'd0;
    for (i = 0; i < 8; i = i + 1)
      active_count = active_count + byte_counts[i*4 +: 4];

    first_active = 6'd0;
    last_active = 6'd0;
    first_seen = 1'b0;
    for (i = 0; i < 64; i = i + 1) begin
      if (mask[i] && !first_seen) begin
        first_active = i[5:0];
        first_seen = 1'b1;
      end
      if (mask[i])
        last_active = i[5:0];
    end
  end
  assign empty = ~(|byte_nonzero);
endmodule
