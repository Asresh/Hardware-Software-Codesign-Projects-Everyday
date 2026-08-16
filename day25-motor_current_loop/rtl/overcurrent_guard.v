// Author: Asresh
`timescale 1ns/1ps
// Independent fast safety comparator; -32768 is widened before magnitude conversion.
module overcurrent_guard (
    input  wire signed [15:0] measured_i,
    input  wire [15:0] trip_i,
    input  wire fault_i,
    output wire trip_o
);
wire [16:0] measured_ext_w = measured_i[15]
    ? (~{measured_i[15], measured_i} + 17'd1)
    : {1'b0, measured_i};
assign trip_o = fault_i | (measured_ext_w > {1'b0, trip_i});
endmodule
