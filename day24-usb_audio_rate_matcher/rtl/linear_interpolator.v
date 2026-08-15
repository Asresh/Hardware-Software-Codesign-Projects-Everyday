// Author: Asresh
// Diagram: prev,current -> signed delta * Q0.16 phase -> rounded sample -> saturate
module linear_interpolator(
  input signed [15:0] prev_i,
  input signed [15:0] curr_i,
  input [15:0] phase_i,
  output signed [15:0] sample_o
);
  wire signed [16:0] delta = $signed(curr_i) - $signed(prev_i);
  wire signed [33:0] product = delta * $signed({1'b0,phase_i});
  wire signed [34:0] wide_sample = $signed(prev_i) + (product / 65536);
  assign sample_o = (wide_sample > 32767) ? 16'sd32767 :
                    (wide_sample < -32768) ? -16'sd32768 : wide_sample[15:0];
endmodule
