// Author: Asresh
`timescale 1ns/1ps
module trace_input_ring #(
    parameter DEPTH = 256,
    parameter AW = 8
) (
    input  wire          clk,
    input  wire          host_we,
    input  wire [AW-1:0] host_addr,
    input  wire [31:0]   host_wdata,
    input  wire [AW-1:0] accel_addr,
    output wire [31:0]   accel_rdata
);
    reg [31:0] mem [0:DEPTH-1];
    always @(posedge clk)
        if (host_we)
            mem[host_addr] <= host_wdata;
    assign accel_rdata = mem[accel_addr];
endmodule
