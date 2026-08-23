// Author: Asresh
`timescale 1ns/1ps
module trace_output_ring #(
    parameter DEPTH = 256,
    parameter AW = 8
) (
    input  wire          clk,
    input  wire          accel_we,
    input  wire [AW-1:0] accel_addr,
    input  wire [63:0]   accel_wdata,
    input  wire [AW-1:0] host_addr,
    input  wire          host_high,
    output wire [31:0]   host_rdata
);
    reg [63:0] mem [0:DEPTH-1];
    always @(posedge clk)
        if (accel_we)
            mem[accel_addr] <= accel_wdata;
    assign host_rdata = host_high ? mem[host_addr][63:32] : mem[host_addr][31:0];
endmodule
