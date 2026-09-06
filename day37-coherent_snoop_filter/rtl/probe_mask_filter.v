// Author: Asresh
`timescale 1ns/1ps
module probe_mask_filter #(
    parameter NODES = 4,
    parameter NODE_BITS = $clog2(NODES)
) (
    input  wire [NODES-1:0]    sharers,
    input  wire [NODE_BITS-1:0] source,
    input  wire                 include_source,
    output wire [NODES-1:0]    probe_mask
);
    wire [NODES-1:0] source_mask;
    assign source_mask = {{(NODES-1){1'b0}}, 1'b1} << source;
    assign probe_mask = include_source ? sharers : (sharers & ~source_mask);
endmodule
