// Author: Asresh
// Driver-visible command engine. Each command names arrays of 8xINT16 logits
// and two packed top-k result words. A sticky W1C interrupt completes the job.
`timescale 1ns/1ps
module ml_topk_command_top #(parameter ADDR_WIDTH=16, parameter MAX_VECTORS=1024)(
 input wire clk,input wire rst_n,input wire mmio_valid,input wire mmio_write,
 input wire [7:0] mmio_addr,input wire [31:0] mmio_wdata,output wire mmio_ready,
 output reg [31:0] mmio_rdata,output wire mem_rd_valid,
 output wire [ADDR_WIDTH-1:0] mem_rd_addr,input wire mem_rd_ready,input wire [31:0] mem_rd_data,
 output wire mem_wr_valid,output wire [ADDR_WIDTH-1:0] mem_wr_addr,
 output wire [31:0] mem_wr_data,input wire mem_wr_ready,output wire irq);
 localparam IDLE=3'd0,READ=3'd1,LAUNCH=3'd2,WAIT_TREE=3'd3,WRITE0=3'd4,WRITE1=3'd5;
 reg [2:0] state; reg [ADDR_WIDTH-1:0] src_base,dst_base; reg [15:0] count,vector_no;
 reg [1:0] word_no; reg [127:0] scores; reg irq_enable,error_sticky,tree_start,done_pulse;
 reg [31:0] cycles; wire tree_valid; wire signed [15:0] v0,v1; wire [2:0] i0,i1;
 wire irq_pending; wire irq_clear=mmio_valid&&mmio_write&&mmio_addr==8'h18&&mmio_wdata[0];
 wire read_accept=mem_rd_valid&&mem_rd_ready; wire write_accept=mem_wr_valid&&mem_wr_ready;
 assign mmio_ready=mmio_valid;
 assign mem_rd_valid=(state==READ);
 assign mem_rd_addr=src_base+({{(ADDR_WIDTH-16){1'b0}},vector_no}<<4)+({{(ADDR_WIDTH-2){1'b0}},word_no}<<2);
 assign mem_wr_valid=(state==WRITE0)||(state==WRITE1);
 assign mem_wr_addr=dst_base+({{(ADDR_WIDTH-16){1'b0}},vector_no}<<3)+(state==WRITE1 ? 4 : 0);
 assign mem_wr_data=(state==WRITE0)?{13'd0,i0,v0}:{13'd0,i1,v1};
 topk_tree8 tree(.clk(clk),.rst_n(rst_n),.start(tree_start),.scores(scores),.valid(tree_valid),
   .top0_value(v0),.top0_index(i0),.top1_value(v1),.top1_index(i1));
 topk_irq_latch il(.clk(clk),.rst_n(rst_n),.enable(irq_enable),.set_pending(done_pulse),
   .clear_pending(irq_clear),.pending(irq_pending),.irq(irq));
 always @* begin
   case(mmio_addr)
    8'h00:mmio_rdata={30'd0,irq_enable,1'b0};
    8'h04:mmio_rdata={29'd0,error_sticky,irq_pending,state!=IDLE};
    8'h08:mmio_rdata={{(32-ADDR_WIDTH){1'b0}},src_base};
    8'h0c:mmio_rdata={{(32-ADDR_WIDTH){1'b0}},dst_base};
    8'h10:mmio_rdata={16'd0,count}; 8'h14:mmio_rdata=cycles;
    8'h18:mmio_rdata={31'd0,irq_pending}; 8'h1c:mmio_rdata={16'd0,vector_no};
    8'h20:mmio_rdata=32'h0008_0201; default:mmio_rdata=0;
   endcase
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin state<=IDLE;src_base<=0;dst_base<=0;count<=0;vector_no<=0;word_no<=0;
   scores<=0;irq_enable<=0;error_sticky<=0;tree_start<=0;done_pulse<=0;cycles<=0;end
  else begin
   tree_start<=0;done_pulse<=0;if(state!=IDLE)cycles<=cycles+1;
   if(mmio_valid&&mmio_write) case(mmio_addr)
    8'h00:begin irq_enable<=mmio_wdata[1];if(mmio_wdata[0]&&state==IDLE)begin
      cycles<=0;vector_no<=0;word_no<=0;error_sticky<=0;
      if(count==0||count>MAX_VECTORS||src_base[1:0]!=0||dst_base[1:0]!=0)begin error_sticky<=1;done_pulse<=1;end
      else state<=READ;end end
    8'h08:src_base<=mmio_wdata[ADDR_WIDTH-1:0]; 8'h0c:dst_base<=mmio_wdata[ADDR_WIDTH-1:0];
    8'h10:count<=mmio_wdata[15:0]; default:begin end
   endcase
   if(state==READ&&read_accept)begin scores[word_no*32 +:32]<=mem_rd_data;
    if(word_no==3)begin word_no<=0;state<=LAUNCH;end else word_no<=word_no+1;end
   else if(state==LAUNCH)begin tree_start<=1;state<=WAIT_TREE;end
   else if(state==WAIT_TREE&&tree_valid)state<=WRITE0;
   else if(state==WRITE0&&write_accept)state<=WRITE1;
   else if(state==WRITE1&&write_accept)begin
    if(vector_no+1==count)begin state<=IDLE;done_pulse<=1;end
    else begin vector_no<=vector_no+1;state<=READ;end end
  end
 end
endmodule
