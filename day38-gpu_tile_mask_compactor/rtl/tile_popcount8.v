// Author: Asresh
`timescale 1ns/1ps
module tile_popcount8(
  input  wire [7:0] bits,
  output wire [3:0] count
);
  assign count = {3'd0,bits[0]} + {3'd0,bits[1]} + {3'd0,bits[2]} + {3'd0,bits[3]} +
                 {3'd0,bits[4]} + {3'd0,bits[5]} + {3'd0,bits[6]} + {3'd0,bits[7]};
endmodule
