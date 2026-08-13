// -----------------------------------------------------------------------------
// philox_round.v
// One combinational Philox-4x32 round: the primitive the whole engine is built
// from. Two 32x32->64 multiplies by the fixed Philox multipliers, then the
// cross/XOR permutation that mixes the high halves back into the counter under
// the round key. Bit-identical to phx_round() in sw/philox_accel.h.
//
//   c = {c3,c2,c1,c0}   (c0 = counter word 0)   key = {k1,k0}
//   {hi0,lo0} = M0 * c0
//   {hi1,lo1} = M1 * c2
//   n0 = hi1 ^ c1 ^ k0 ; n1 = lo1 ; n2 = hi0 ^ c3 ^ k1 ; n3 = lo0
// -----------------------------------------------------------------------------
`default_nettype none

module philox_round (
    input  wire [127:0] ctr,
    input  wire [63:0]  key,
    output wire [127:0] nxt
);
    localparam [31:0] M0 = 32'hD2511F53;
    localparam [31:0] M1 = 32'hCD9E8D57;

    wire [31:0] c0 = ctr[31:0];
    wire [31:0] c1 = ctr[63:32];
    wire [31:0] c2 = ctr[95:64];
    wire [31:0] c3 = ctr[127:96];
    wire [31:0] k0 = key[31:0];
    wire [31:0] k1 = key[63:32];

    // full-width 32x32->64 products (zero-extend operands so the multiply is
    // evaluated at 64 bits on every simulator/synthesizer)
    wire [63:0] p0 = {32'd0, c0} * {32'd0, M0};
    wire [63:0] p1 = {32'd0, c2} * {32'd0, M1};

    wire [31:0] hi0 = p0[63:32], lo0 = p0[31:0];
    wire [31:0] hi1 = p1[63:32], lo1 = p1[31:0];

    wire [31:0] n0 = hi1 ^ c1 ^ k0;
    wire [31:0] n1 = lo1;
    wire [31:0] n2 = hi0 ^ c3 ^ k1;
    wire [31:0] n3 = lo0;

    assign nxt = {n3, n2, n1, n0};
endmodule

`default_nettype wire
