// Author: Asresh
// Selected/ready MMIO control plane with sticky W1C completion/error interrupt.
module sobel_csr #(parameter MAX_WIDTH=64)(input wire clk,input wire rst_n,input wire bus_valid_i,input wire bus_write_i,input wire [5:0] bus_addr_i,input wire [31:0] bus_wdata_i,output wire bus_ready_o,output reg [31:0] bus_rdata_o,output reg [15:0] width_o,output reg [15:0] height_o,output reg start_o,input wire running_i,input wire done_i,input wire error_i,input wire [31:0] pixels_in_i,input wire [31:0] pixels_out_i,output wire irq_o);
 reg irq_enable,irq_pending,error_sticky; assign bus_ready_o=bus_valid_i;assign irq_o=irq_enable&&irq_pending;
 always @* begin case(bus_addr_i)
  6'h00:bus_rdata_o={30'd0,irq_enable,1'b1};6'h04:bus_rdata_o={16'd0,width_o};6'h08:bus_rdata_o={16'd0,height_o};
  6'h0c:bus_rdata_o={28'd0,error_sticky,irq_pending,running_i,!running_i};6'h10:bus_rdata_o=pixels_in_i;6'h14:bus_rdata_o=pixels_out_i;
  6'h18:bus_rdata_o={30'd0,error_sticky,irq_pending};6'h1c:bus_rdata_o={16'd64,16'h2601};default:bus_rdata_o=0;endcase end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin width_o<=16'd8;height_o<=16'd8;irq_enable<=0;irq_pending<=0;error_sticky<=0;start_o<=0;end else begin start_o<=0;if(done_i)irq_pending<=1;if(error_i)begin irq_pending<=1;error_sticky<=1;end
   if(bus_valid_i&&bus_write_i)case(bus_addr_i)6'h00:begin irq_enable<=bus_wdata_i[1];if(bus_wdata_i[8])start_o<=1;end 6'h04:width_o<=bus_wdata_i[15:0];6'h08:height_o<=bus_wdata_i[15:0];6'h18:begin if(bus_wdata_i[0])irq_pending<=0;if(bus_wdata_i[1])error_sticky<=0;end default:begin end endcase
  end end
endmodule
