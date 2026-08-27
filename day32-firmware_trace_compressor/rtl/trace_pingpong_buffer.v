// Author: Asresh
`timescale 1ns/1ps
module trace_pingpong_buffer #(
    parameter BANK_DEPTH = 8,
    parameter BW = 3
) (
    input  wire          clk,
    input  wire          wr_en,
    input  wire          wr_bank,
    input  wire [BW-1:0] wr_addr,
    input  wire [31:0]   wr_data,
    input  wire          rd_bank,
    input  wire [BW-1:0] rd_addr,
    output wire [31:0]   rd_data
);
    reg [31:0] bank0 [0:BANK_DEPTH-1];
    reg [31:0] bank1 [0:BANK_DEPTH-1];
    always @(posedge clk)
        if (wr_en) begin
            if (wr_bank) bank1[wr_addr] <= wr_data;
            else         bank0[wr_addr] <= wr_data;
        end
    assign rd_data = rd_bank ? bank1[rd_addr] : bank0[rd_addr];
endmodule
