// Author: Asresh
// Diagram: signed fill error * proportional gain -> clamp -> phase correction
module pi_rate_controller(
  input signed [16:0] error_i,
  input [15:0] gain_q8_i,
  output signed [16:0] correction_o
);
  wire signed [33:0] product = error_i * $signed({1'b0,gain_q8_i});
  wire signed [33:0] scaled = product / 256;
  assign correction_o = (scaled > 32767) ? 17'sd32767 :
                        (scaled < -32768) ? -17'sd32768 : scaled[16:0];
endmodule
