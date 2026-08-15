// Author: Asresh
// Diagram: stream -> [fill error] -> [rate control] -> [interpolator] -> stream/IRQ
module usb_audio_rate_matcher #(
  parameter LEVEL_W=16
)(
  input clk, input rst_n, input enable_i,
  input [LEVEL_W-1:0] target_fill_i, input [15:0] gain_q8_i,
  input s_valid_i, output s_ready_o, input signed [15:0] s_prev_i,
  input signed [15:0] s_curr_i, input [LEVEL_W-1:0] s_fill_i, input s_last_i,
  output m_valid_o, input m_ready_i, output signed [15:0] m_sample_o,
  output m_last_o, output reg [31:0] sample_count_o, output reg done_pulse_o
);
  reg v0,v1,v2,last0,last1,last2;
  reg signed [15:0] prev0,curr0,prev1,curr1;
  reg signed [16:0] corr0;
  reg [15:0] phase1;
  reg signed [15:0] out_sample;
  wire advance = m_ready_i || !v2;
  assign s_ready_o = enable_i && advance;
  wire signed [16:0] err_comb;
  wire signed [16:0] corr_comb;
  fill_error #(.LEVEL_W(LEVEL_W)) u_error(s_fill_i,target_fill_i,err_comb);
  pi_rate_controller u_control(err_comb,gain_q8_i,corr_comb);

  wire signed [17:0] phase_sum = 18'sd32768 + corr0;
  wire [15:0] phase_clamped = phase_sum < 0 ? 16'd0 :
                              phase_sum > 65535 ? 16'hffff : phase_sum[15:0];
  wire signed [15:0] interp;
  linear_interpolator u_interp(prev1,curr1,phase1,interp);
  assign m_valid_o=v2; assign m_sample_o=out_sample; assign m_last_o=last2;

  always @(posedge clk) begin
    if(!rst_n) begin
      v0<=0;v1<=0;v2<=0;last0<=0;last1<=0;last2<=0;
      sample_count_o<=0;done_pulse_o<=0;out_sample<=0;
      prev0<=0;curr0<=0;prev1<=0;curr1<=0;corr0<=0;phase1<=0;
    end else begin
      done_pulse_o<=0;
      if(advance) begin
        v2<=v1; last2<=last1; out_sample<=interp;
        v1<=v0; last1<=last0; prev1<=prev0; curr1<=curr0;
        phase1<=phase_clamped;
        v0<=s_valid_i && s_ready_o;
        if(s_valid_i && s_ready_o) begin
          prev0<=s_prev_i; curr0<=s_curr_i; corr0<=corr_comb; last0<=s_last_i;
        end
      end
      if(m_valid_o && m_ready_i) begin
        sample_count_o<=sample_count_o+1;
        if(m_last_o) done_pulse_o<=1;
      end
    end
  end
endmodule
