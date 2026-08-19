// Author: Asresh
module reachability_lane #(parameter NODES=16, parameter WIDTH=4, parameter BASE=0)(
 input [NODES-1:0] frontier,
 input [NODES*NODES-1:0] adjacency_flat,
 output reg [WIDTH-1:0] hits
);
integer d,s;
always @* begin
 hits={WIDTH{1'b0}};
 for(d=0;d<WIDTH;d=d+1)
  for(s=0;s<NODES;s=s+1)
   if(frontier[s] && adjacency_flat[s*NODES+BASE+d]) hits[d]=1'b1;
end
endmodule
