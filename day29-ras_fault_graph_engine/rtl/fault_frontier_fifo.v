// Author: Asresh
module fault_frontier_fifo #(parameter NODES=16)(
 input clk,input rst_n,input load,input advance,
 input [NODES-1:0] load_value,input [NODES-1:0] next_value,
 output reg [NODES-1:0] frontier
);
always @(posedge clk) begin
 if(!rst_n) frontier<={NODES{1'b0}};
 else if(load) frontier<=load_value;
 else if(advance) frontier<=next_value;
end
endmodule
