// Author: Asresh
// Top-level mailbox, policy core, associative nonce table, telemetry, and IRQ.
module spdm_replay_guard_top #(parameter integer ENTRIES=32,INDEX_W=5,CONTEXTS=8,CONTEXT_W=3)(input wire clk,rst_n,input wire bus_valid,bus_write,input wire [7:0] bus_addr,input wire [31:0] bus_wdata,output wire bus_ready,output wire [31:0] bus_rdata,output wire irq);
wire qv,qr,sv,sr,sa;wire [1:0]op;wire [CONTEXT_W-1:0]ctx;wire [15:0]ep;wire [127:0]nonce;wire [2:0]reason;wire [INDEX_W-1:0]slot;wire [31:0]ac,rc,sc;
replay_guard_csr #(.INDEX_W(INDEX_W),.CONTEXT_W(CONTEXT_W)) csr(clk,rst_n,bus_valid,bus_write,bus_addr,bus_wdata,bus_ready,bus_rdata,qv,qr,op,ctx,ep,nonce,sv,sr,sa,reason,slot,ac,rc,sc,irq);
replay_guard_core #(.ENTRIES(ENTRIES),.INDEX_W(INDEX_W),.CONTEXTS(CONTEXTS),.CONTEXT_W(CONTEXT_W)) core(clk,rst_n,qv,qr,op,ctx,ep,nonce,sv,sr,sa,reason,slot,ac,rc,sc);
endmodule
