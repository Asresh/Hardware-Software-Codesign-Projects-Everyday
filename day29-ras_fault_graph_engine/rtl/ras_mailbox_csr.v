// Author: Asresh
module ras_mailbox_csr #(parameter NODES=16)(
 input clk,input rst_n,input bus_valid,input bus_write,input [7:0] bus_addr,input [31:0] bus_wdata,
 output bus_ready,output reg [31:0] bus_rdata,output irq,
 output reg start,output reg [NODES-1:0] seed,output reg [NODES*NODES-1:0] adjacency_flat,
 input busy,input done,input [NODES-1:0] reached,input [7:0] iterations
);
reg irq_en,irq_pending;reg[7:0]row_index;reg[31:0]requests;integer k;reg[7:0]pop;
localparam [7:0] NODE_COUNT=NODES;
localparam [7:0] LANE_COUNT=NODES/4;
assign bus_ready=bus_valid;assign irq=irq_en&&irq_pending;
always @* begin pop=0;for(k=0;k<NODES;k=k+1)pop=pop+reached[k];end
always @* begin
 case(bus_addr)
  8'h00:bus_rdata={28'd0,irq_pending,busy,irq_en,1'b0};
  8'h04:bus_rdata={{(32-NODES){1'b0}},seed};
  8'h08:bus_rdata={24'd0,row_index};
  8'h0c:bus_rdata={{(32-NODES){1'b0}},adjacency_flat[row_index*NODES +: NODES]};
  8'h10:bus_rdata={{(32-NODES){1'b0}},reached};
  8'h14:bus_rdata={24'd0,iterations};
  8'h18:bus_rdata={24'd0,pop};
  8'h1c:bus_rdata=requests;
  8'h20:bus_rdata={8'h52,8'h41,NODE_COUNT,LANE_COUNT};
  default:bus_rdata=0;
 endcase
end
always @(posedge clk) begin
 start<=0;
 if(!rst_n) begin irq_en<=0;irq_pending<=0;seed<=0;row_index<=0;adjacency_flat<=0;requests<=0;end
 else begin
  if(done) irq_pending<=1;
  if(bus_valid&&bus_write) case(bus_addr)
   8'h00:begin irq_en<=bus_wdata[1];if(bus_wdata[0]&&!busy)begin start<=1;requests<=requests+1'b1;end if(bus_wdata[3])irq_pending<=0;end
   8'h04:seed<=bus_wdata[NODES-1:0];
   8'h08:row_index<=bus_wdata[7:0];
   8'h0c:if(row_index<NODES)adjacency_flat[row_index*NODES +: NODES]<=bus_wdata[NODES-1:0];
  endcase
 end
end
endmodule
