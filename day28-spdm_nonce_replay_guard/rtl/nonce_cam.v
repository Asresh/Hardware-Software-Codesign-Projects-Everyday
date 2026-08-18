// Author: Asresh
// Parameterized content-addressable nonce table with epoch-qualified matches.
module nonce_cam #(parameter integer ENTRIES=32, INDEX_W=5, CONTEXT_W=3, EPOCH_W=16)(
 input wire clk,rst_n,input wire [CONTEXT_W-1:0] query_context,input wire [EPOCH_W-1:0] query_epoch,input wire [127:0] query_nonce,
 output wire match_valid,output wire [INDEX_W-1:0] match_index,output wire free_valid,output wire [INDEX_W-1:0] free_index,
 input wire insert_en,input wire [INDEX_W-1:0] insert_index,input wire invalidate_context_en,input wire [CONTEXT_W-1:0] invalidate_context,input wire flush_all);
reg [ENTRIES-1:0] valid_bits; reg [CONTEXT_W-1:0] contexts[0:ENTRIES-1]; reg [EPOCH_W-1:0] epochs[0:ENTRIES-1]; reg [127:0] nonces[0:ENTRIES-1];
wire [ENTRIES-1:0] match_mask,free_mask; integer i; genvar g;
generate for(g=0;g<ENTRIES;g=g+1) begin:gm
 assign match_mask[g]=valid_bits[g]&&(contexts[g]==query_context)&&(epochs[g]==query_epoch)&&(nonces[g]==query_nonce);
 assign free_mask[g]=!valid_bits[g]; end endgenerate
priority_encoder #(.WIDTH(ENTRIES),.INDEX_W(INDEX_W)) pm(match_mask,match_valid,match_index);
priority_encoder #(.WIDTH(ENTRIES),.INDEX_W(INDEX_W)) pf(free_mask,free_valid,free_index);
always @(posedge clk) begin
 if(!rst_n) begin valid_bits<=0; for(i=0;i<ENTRIES;i=i+1) begin contexts[i]<=0;epochs[i]<=0;nonces[i]<=0;end end
 else begin
  if(flush_all) valid_bits<=0; else if(invalidate_context_en) for(i=0;i<ENTRIES;i=i+1) if(valid_bits[i]&&contexts[i]==invalidate_context) valid_bits[i]<=0;
  if(insert_en) begin valid_bits[insert_index]<=1;contexts[insert_index]<=query_context;epochs[insert_index]<=query_epoch;nonces[insert_index]<=query_nonce;end
 end end
endmodule
