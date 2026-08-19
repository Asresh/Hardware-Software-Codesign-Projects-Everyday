// Author: Asresh
module ras_fault_graph_top #(parameter NODES=16)(
 input clk,input rst_n,input bus_valid,input bus_write,input[7:0]bus_addr,input[31:0]bus_wdata,
 output bus_ready,output[31:0]bus_rdata,output irq
);
wire start,busy,done;wire[NODES-1:0]seed,reached;wire[NODES*NODES-1:0]adjacency_flat;wire[7:0]iterations;
ras_mailbox_csr #(NODES) csr(clk,rst_n,bus_valid,bus_write,bus_addr,bus_wdata,bus_ready,bus_rdata,irq,start,seed,adjacency_flat,busy,done,reached,iterations);
fault_graph_core #(NODES) core(clk,rst_n,start,seed,adjacency_flat,busy,done,reached,iterations);
endmodule
