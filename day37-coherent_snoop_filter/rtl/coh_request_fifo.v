// Author: Asresh
`timescale 1ns/1ps
module coh_request_fifo #(
    parameter WIDTH = 21
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             clear,
    input  wire             in_valid,
    output wire             in_ready,
    input  wire [WIDTH-1:0] in_data,
    output wire             out_valid,
    input  wire             out_ready,
    output wire [WIDTH-1:0] out_data
);
    reg full;
    reg [WIDTH-1:0] data;

    assign in_ready = ~full | out_ready;
    assign out_valid = full;
    assign out_data = data;

    always @(posedge clk) begin
        if (rst || clear) begin
            full <= 1'b0;
            data <= {WIDTH{1'b0}};
        end else if (in_ready) begin
            full <= in_valid;
            if (in_valid)
                data <= in_data;
        end
    end
endmodule
