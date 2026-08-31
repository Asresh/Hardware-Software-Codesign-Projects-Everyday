// Author: Asresh
// Selects the best and second-best signed score from two lanes. Ties prefer
// the lower lane index, matching deterministic inference-runtime behavior.
`timescale 1ns/1ps
module topk_pair (
    input wire signed [15:0] a_value, input wire [2:0] a_index,
    input wire signed [15:0] b_value, input wire [2:0] b_index,
    output reg signed [15:0] first_value, output reg [2:0] first_index,
    output reg signed [15:0] second_value, output reg [2:0] second_index
);
    always @* begin
        if ((a_value > b_value) || ((a_value == b_value) && (a_index < b_index))) begin
            first_value = a_value; first_index = a_index;
            second_value = b_value; second_index = b_index;
        end else begin
            first_value = b_value; first_index = b_index;
            second_value = a_value; second_index = a_index;
        end
    end
endmodule
