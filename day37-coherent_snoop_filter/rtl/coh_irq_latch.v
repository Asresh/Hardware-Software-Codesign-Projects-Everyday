// Author: Asresh
`timescale 1ns/1ps
module coh_irq_latch (
    input  wire clk,
    input  wire rst,
    input  wire set_i,
    input  wire clear_i,
    output reg  pending
);
    always @(posedge clk) begin
        if (rst)
            pending <= 1'b0;
        else if (set_i)
            pending <= 1'b1;
        else if (clear_i)
            pending <= 1'b0;
    end
endmodule
