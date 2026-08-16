// Author: Asresh
`timescale 1ns/1ps
// Signed phase-current error front end.
module phase_error (
    input  wire signed [15:0] reference_i,
    input  wire signed [15:0] measured_i,
    output wire signed [16:0] error_o
);
assign error_o = {reference_i[15], reference_i} - {measured_i[15], measured_i};
endmodule
