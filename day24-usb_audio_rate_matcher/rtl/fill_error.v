// Author: Asresh
// Diagram: fill_level,target_fill -> subtract -> signed FIFO error
module fill_error #(parameter LEVEL_W=16)(
  input [LEVEL_W-1:0] fill_level_i,
  input [LEVEL_W-1:0] target_fill_i,
  output signed [LEVEL_W:0] error_o
);
  assign error_o = $signed({1'b0,target_fill_i}) - $signed({1'b0,fill_level_i});
endmodule
