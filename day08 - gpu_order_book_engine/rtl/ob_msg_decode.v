// ============================================================================
// ob_msg_decode - unpack a 64-bit AXI4-Stream market-data beat into fields.
//
// Field offsets are derived from QW/PW exactly as the software header lob.h
// derives them, so the hardware and the golden model agree bit-for-bit.
//   [QW-1:0]        quantity
//   [QW+PW-1:QW]    price (ticks)
//   [QW+PW]         side  (0 = bid, 1 = ask)
//   [QW+PW+2:QW+PW+1] op  (0 ADD, 1 SUB, 2 SET, 3 CLR)
// Purely combinational.
// ============================================================================
`default_nettype none
module ob_msg_decode #(
    parameter integer QW   = 24,
    parameter integer PW   = 16,
    parameter integer MSGW = 64
) (
    input  wire [MSGW-1:0] beat,
    output wire [1:0]      op,
    output wire            side,
    output wire [PW-1:0]   price,
    output wire [QW-1:0]   qty
);
    assign qty   = beat[QW-1:0];
    assign price = beat[QW +: PW];
    assign side  = beat[QW+PW];
    assign op    = beat[QW+PW+1 +: 2];
endmodule
`default_nettype wire
