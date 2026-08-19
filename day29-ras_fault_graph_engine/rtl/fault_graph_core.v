// Author: Asresh
module fault_graph_core #(parameter NODES=16)(
 input clk,input rst_n,input start,input [NODES-1:0] seed,
 input [NODES*NODES-1:0] adjacency_flat,
 output reg busy,output reg done,output reg [NODES-1:0] reached,
 output reg [7:0] iterations
);
wire [NODES-1:0] neighbors,expanded,frontier;
genvar g;
generate for(g=0;g<NODES;g=g+4) begin:lanes
 reachability_lane #(NODES,4,g) lane(frontier,adjacency_flat,neighbors[g +: 4]);
end endgenerate
assign expanded=neighbors & ~reached;
fault_frontier_fifo #(NODES) ff(clk,rst_n,start,busy && (expanded!={NODES{1'b0}}),seed,expanded,frontier);
always @(posedge clk) begin
 if(!rst_n) begin busy<=0;done<=0;reached<=0;iterations<=0;end
 else begin
  done<=0;
  if(start && !busy) begin busy<=1;reached<=seed;iterations<=0;end
  else if(busy) begin
   iterations<=iterations+1'b1;
   if(expanded=={NODES{1'b0}}) begin busy<=0;done<=1;end
   else reached<=reached|expanded;
  end
 end
end
endmodule
