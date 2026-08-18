// Author: Asresh
// Freshness policy, parallel replay decision, insertion, and round-robin replacement.
module replay_guard_core #(parameter integer ENTRIES=32,INDEX_W=5,CONTEXTS=8,CONTEXT_W=3,EPOCH_W=16)(
 input wire clk,rst_n,input wire req_valid,output wire req_ready,input wire [1:0] req_op,input wire [CONTEXT_W-1:0] req_context,input wire [EPOCH_W-1:0] req_epoch,input wire [127:0] req_nonce,
 output reg rsp_valid,input wire rsp_ready,output reg rsp_accept,output reg [2:0] rsp_reason,output reg [INDEX_W-1:0] rsp_slot,
 output reg [31:0] accepted_count,replay_count,stale_count);
localparam [1:0] CHECK=0,SET_EPOCH=1,FLUSH_CTX=2,FLUSH_ALL=3; localparam [2:0] ACCEPT=0,REPLAY=1,STALE=2,EPOCH_SET=3,FLUSHED=4;
reg [EPOCH_W-1:0] floor[0:CONTEXTS-1]; reg [INDEX_W-1:0] replace_ptr; wire match_valid,free_valid; wire [INDEX_W-1:0] match_index,free_index;
reg insert_en,invalidate_context_en,flush_all; reg [INDEX_W-1:0] insert_index; integer i;
assign req_ready=!rsp_valid||rsp_ready;
nonce_cam #(.ENTRIES(ENTRIES),.INDEX_W(INDEX_W),.CONTEXT_W(CONTEXT_W),.EPOCH_W(EPOCH_W)) cam(clk,rst_n,req_context,req_epoch,req_nonce,match_valid,match_index,free_valid,free_index,insert_en,insert_index,invalidate_context_en,req_context,flush_all);
always @* begin insert_en=0;invalidate_context_en=0;flush_all=0;insert_index=free_valid?free_index:replace_ptr;
 if(req_valid&&req_ready) begin if(req_op==CHECK&&req_epoch>=floor[req_context]&&!match_valid) insert_en=1; if(req_op==SET_EPOCH||req_op==FLUSH_CTX) invalidate_context_en=1; if(req_op==FLUSH_ALL) flush_all=1; end end
always @(posedge clk) begin
 if(!rst_n) begin rsp_valid<=0;rsp_accept<=0;rsp_reason<=0;rsp_slot<=0;replace_ptr<=0;accepted_count<=0;replay_count<=0;stale_count<=0;for(i=0;i<CONTEXTS;i=i+1)floor[i]<=0;end
 else begin
  if(rsp_valid&&rsp_ready)rsp_valid<=0;
  if(req_valid&&req_ready) begin rsp_valid<=1;rsp_slot<=0;rsp_accept<=1;
   case(req_op)
    CHECK: if(req_epoch<floor[req_context])begin rsp_accept<=0;rsp_reason<=STALE;stale_count<=stale_count+1;end else if(match_valid)begin rsp_accept<=0;rsp_reason<=REPLAY;rsp_slot<=match_index;replay_count<=replay_count+1;end else begin rsp_reason<=ACCEPT;rsp_slot<=free_valid?free_index:replace_ptr;accepted_count<=accepted_count+1;if(!free_valid)replace_ptr<=(replace_ptr==ENTRIES-1)?0:replace_ptr+1;end
    SET_EPOCH:begin floor[req_context]<=req_epoch;rsp_reason<=EPOCH_SET;end
    FLUSH_CTX:rsp_reason<=FLUSHED; default:rsp_reason<=FLUSHED; endcase
  end
 end end
endmodule
