// Author: Asresh
// Parameterized elastic FIFO used to isolate host stream timing from the stencil.
module pixel_fifo #(parameter WIDTH=9, parameter DEPTH=4, parameter PTR_W=2)(
 input wire clk,input wire rst_n,input wire s_valid,output wire s_ready,input wire [WIDTH-1:0] s_data,
 output wire m_valid,input wire m_ready,output wire [WIDTH-1:0] m_data,output wire [PTR_W:0] level);
 reg [WIDTH-1:0] mem[0:DEPTH-1]; reg [PTR_W-1:0] rd_ptr,wr_ptr; reg [PTR_W:0] count;
 wire push=s_valid&&s_ready, pop=m_valid&&m_ready;
 assign s_ready=(count<DEPTH); assign m_valid=(count!=0); assign m_data=mem[rd_ptr]; assign level=count;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin rd_ptr<=0;wr_ptr<=0;count<=0;end else begin
   if(push) begin mem[wr_ptr]<=s_data;wr_ptr<=wr_ptr+1'b1;end if(pop) rd_ptr<=rd_ptr+1'b1;
   case({push,pop}) 2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:count<=count;endcase
  end
 end
endmodule
