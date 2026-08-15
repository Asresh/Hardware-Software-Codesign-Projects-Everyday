// Author: Asresh
// Diagram: host MMIO + USB audio stream -> registers + rate matcher -> codec stream/IRQ
module usb_audio_mmio_top(
  input clk,input rst_n,input bus_valid_i,input bus_write_i,input [5:0] bus_addr_i,
  input [31:0] bus_wdata_i,output bus_ready_o,output [31:0] bus_rdata_o,
  input s_valid_i,output s_ready_o,input signed [15:0] s_prev_i,input signed [15:0] s_curr_i,
  input [15:0] s_fill_i,input s_last_i,output m_valid_o,input m_ready_i,
  output signed [15:0] m_sample_o,output m_last_o,output irq_o
);
  wire enable,irq_enable,done; wire [15:0] target,gain; wire [31:0] count;
  usb_audio_mmio_regs u_regs(clk,rst_n,bus_valid_i,bus_write_i,bus_addr_i,bus_wdata_i,
    bus_ready_o,bus_rdata_o,done,count,enable,irq_enable,target,gain,irq_o);
  usb_audio_rate_matcher u_core(clk,rst_n,enable,target,gain,s_valid_i,s_ready_o,s_prev_i,
    s_curr_i,s_fill_i,s_last_i,m_valid_o,m_ready_i,m_sample_o,m_last_o,count,done);
endmodule
