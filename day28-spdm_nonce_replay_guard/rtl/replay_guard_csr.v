// Author: Asresh
// Selected/ready mailbox register file and sticky completion interrupt.
module replay_guard_csr #(parameter integer INDEX_W=5,CONTEXT_W=3)(input wire clk,rst_n,input wire bus_valid,bus_write,input wire [7:0] bus_addr,input wire [31:0] bus_wdata,output reg bus_ready,output reg [31:0] bus_rdata,
 output reg req_valid,input wire req_ready,output reg [1:0] req_op,output reg [CONTEXT_W-1:0] req_context,output reg [15:0] req_epoch,output reg [127:0] req_nonce,
 input wire rsp_valid,output wire rsp_ready,input wire rsp_accept,input wire [2:0] rsp_reason,input wire [INDEX_W-1:0] rsp_slot,input wire [31:0] accepted_count,replay_count,stale_count,output wire irq);
reg irq_enable,irq_status;reg [31:0] result;assign rsp_ready=1;assign irq=irq_enable&&irq_status;
always @* begin bus_ready=bus_valid;case(bus_addr) 0:bus_rdata={28'b0,irq_status,1'b0,irq_enable,1'b0};8'h04:bus_rdata={11'b0,req_epoch,2'b0,req_context};8'h08:bus_rdata=req_nonce[31:0];8'h0c:bus_rdata=req_nonce[63:32];8'h10:bus_rdata=req_nonce[95:64];8'h14:bus_rdata=req_nonce[127:96];8'h18:bus_rdata=result;8'h1c:bus_rdata=accepted_count;8'h20:bus_rdata=replay_count;8'h24:bus_rdata=stale_count;8'h28:bus_rdata=32'h52504731;default:bus_rdata=0;endcase end
always @(posedge clk) begin if(!rst_n)begin req_valid<=0;req_op<=0;req_context<=0;req_epoch<=0;req_nonce<=0;irq_enable<=0;irq_status<=0;result<=0;end else begin
 if(req_valid&&req_ready)req_valid<=0;if(rsp_valid)begin result<={{(24-INDEX_W){1'b0}},rsp_slot,rsp_reason,rsp_accept};irq_status<=1;end
 if(bus_valid&&bus_write)case(bus_addr) 0:begin irq_enable<=bus_wdata[1];if(bus_wdata[3])irq_status<=0;if(bus_wdata[0]&&!req_valid)begin req_op<=bus_wdata[9:8];req_valid<=1;end end
 8'h04:begin req_context<=bus_wdata[2:0];req_epoch<=bus_wdata[20:5];end 8'h08:req_nonce[31:0]<=bus_wdata;8'h0c:req_nonce[63:32]<=bus_wdata;8'h10:req_nonce[95:64]<=bus_wdata;8'h14:req_nonce[127:96]<=bus_wdata;endcase end end
endmodule
