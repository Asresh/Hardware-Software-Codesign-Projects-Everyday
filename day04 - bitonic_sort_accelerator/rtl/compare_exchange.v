// -----------------------------------------------------------------------------
// compare_exchange.v
// The atomic building block of every sorting network: a 2-input compare-exchange
// (CAE) cell. Given two unsigned keys and a direction, it emits the pair ordered
// so the "lo" port carries the value that belongs at the lower array index.
//
//   asc = 1 : lo = min(a,b), hi = max(a,b)   (ascending)
//   asc = 0 : lo = max(a,b), hi = min(a,b)   (descending)
//
// One combinational comparator + two muxes. A full bitonic network is nothing
// but N/2 of these per stage; making the cell its own module keeps the network
// generate loop readable and gives synthesis a single point of truth for the
// comparator's cost. Pure combinational; the pipeline registers live in
// bitonic_network.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module compare_exchange #(
    parameter integer W = 32        // key width in bits (unsigned compare)
)(
    input  wire [W-1:0] a,          // key at the lower array index
    input  wire [W-1:0] b,          // key at the higher array index
    input  wire         asc,        // 1 = ascending, 0 = descending
    output wire [W-1:0] lo,         // value routed back to the lower index
    output wire [W-1:0] hi          // value routed back to the higher index
);
    wire a_le_b = (a <= b);
    wire [W-1:0] min_ab = a_le_b ? a : b;
    wire [W-1:0] max_ab = a_le_b ? b : a;

    assign lo = asc ? min_ab : max_ab;
    assign hi = asc ? max_ab : min_ab;
endmodule

`default_nettype wire
