// Author: Asresh
`timescale 1ns/1ps
module power_peak_selector #(
    parameter BINS = 4
) (
    input  wire [(BINS*64)-1:0] powers,
    output reg  [63:0]           peak_power,
    output reg  [7:0]            peak_bin
);
    integer i;
    reg [63:0] candidate;
    always @* begin
        peak_power = powers[63:0];
        peak_bin = 8'd0;
        for (i = 1; i < BINS; i = i + 1) begin
            candidate = powers[(i*64) +: 64];
            if (candidate > peak_power) begin
                peak_power = candidate;
                peak_bin = i;
            end
        end
    end
endmodule
