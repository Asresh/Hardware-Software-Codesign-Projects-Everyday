// Author: Asresh
module priority_encoder #(parameter integer WIDTH=32, parameter integer INDEX_W=5)(input wire [WIDTH-1:0] request, output reg valid, output reg [INDEX_W-1:0] index);
integer i; always @* begin valid=0; index=0; for(i=WIDTH-1;i>=0;i=i-1) if(request[i]) begin valid=1; index=i[INDEX_W-1:0]; end end
endmodule
