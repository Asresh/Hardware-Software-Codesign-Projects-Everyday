// Author: Asresh
// Diagram: host selected/ready MMIO -> configuration/status -> sticky IRQ
module usb_audio_mmio_regs(
  input clk,input rst_n,input bus_valid_i,input bus_write_i,input [5:0] bus_addr_i,
  input [31:0] bus_wdata_i,output bus_ready_o,output reg [31:0] bus_rdata_o,
  input done_pulse_i,input [31:0] sample_count_i,
  output reg enable_o,output reg irq_enable_o,output reg [15:0] target_fill_o,
  output reg [15:0] gain_q8_o,output irq_o
);
  reg irq_status;
  assign bus_ready_o=bus_valid_i;
  assign irq_o=irq_status && irq_enable_o;
  always @(*) begin
    case(bus_addr_i)
      6'h00:bus_rdata_o={30'd0,irq_enable_o,enable_o};
      6'h04:bus_rdata_o={16'd0,target_fill_o};
      6'h08:bus_rdata_o={16'd0,gain_q8_o};
      6'h0c:bus_rdata_o={30'd0,irq_status,enable_o};
      6'h10:bus_rdata_o=sample_count_i;
      6'h14:bus_rdata_o={31'd0,irq_status};
      default:bus_rdata_o=32'd0;
    endcase
  end
  always @(posedge clk) begin
    if(!rst_n) begin enable_o<=0;irq_enable_o<=0;target_fill_o<=16'd128;gain_q8_o<=16'd64;irq_status<=0; end
    else begin
      if(done_pulse_i) irq_status<=1;
      if(bus_valid_i && bus_write_i) case(bus_addr_i)
        6'h00:begin enable_o<=bus_wdata_i[0];irq_enable_o<=bus_wdata_i[1];end
        6'h04:target_fill_o<=bus_wdata_i[15:0];
        6'h08:gain_q8_o<=bus_wdata_i[15:0];
        6'h14:if(bus_wdata_i[0]) irq_status<=0;
      endcase
    end
  end
endmodule
