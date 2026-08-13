// -----------------------------------------------------------------------------
// philox_lane.v
// One fully-pipelined Philox-4x32-10 lane: ROUNDS combinational round stages
// separated by pipeline registers, so it accepts a fresh 128-bit counter every
// clock and retires that counter's 128-bit random block ROUNDS cycles later -
// one draw per clock, per lane, at full throughput.
//
// The key schedule is unrolled as constants of the job key: round r uses
// {k1 + r*W1, k0 + r*W0} (the Weyl bump), matching phx_block() which bumps the
// key before rounds 1..ROUNDS-1. A valid bit is pipelined alongside the datapath
// so downstream logic knows when an output block is real.
// -----------------------------------------------------------------------------
`default_nettype none

module philox_lane #(
    parameter integer ROUNDS = 10
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         in_valid,
    input  wire [127:0] in_ctr,
    input  wire [63:0]  key,
    output wire         out_valid,
    output wire [127:0] out_ctr
);
    localparam [31:0] W0 = 32'h9E3779B9;   // golden ratio
    localparam [31:0] W1 = 32'hBB67AE85;   // sqrt(3)-1

    wire [31:0] k0 = key[31:0];
    wire [31:0] k1 = key[63:32];

    // per-round key: constants of the job key (r*W is an elaboration constant)
    wire [63:0] kr [0:ROUNDS-1];
    genvar r;
    generate
        for (r = 0; r < ROUNDS; r = r + 1) begin : keygen
            wire [31:0] krh = k1 + W1 * r;   // sized 32-bit adds so the
            wire [31:0] krl = k0 + W0 * r;   // concatenation width is definite
            assign kr[r] = { krh, krl };
        end
    endgenerate

    // pipeline registers: d[s] holds the counter after s rounds (s = 1..ROUNDS)
    reg  [127:0] d [1:ROUNDS];
    reg          v [1:ROUNDS];
    wire [127:0] rnd_out [1:ROUNDS];

    // stage s applies round index (s-1) with key kr[s-1]; stage 1 reads the live
    // input, later stages read the previous pipeline register
    generate
        for (r = 1; r <= ROUNDS; r = r + 1) begin : stage
            if (r == 1) begin : first
                philox_round u_round (
                    .ctr( in_ctr ), .key( kr[0] ), .nxt( rnd_out[1] )
                );
            end else begin : rest
                philox_round u_round (
                    .ctr( d[r-1] ), .key( kr[r-1] ), .nxt( rnd_out[r] )
                );
            end
        end
    endgenerate

    integer s;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (s = 1; s <= ROUNDS; s = s + 1) begin
                d[s] <= 128'd0;
                v[s] <= 1'b0;
            end
        end else begin
            d[1] <= rnd_out[1];
            v[1] <= in_valid;
            for (s = 2; s <= ROUNDS; s = s + 1) begin
                d[s] <= rnd_out[s];
                v[s] <= v[s-1];
            end
        end
    end

    assign out_ctr   = d[ROUNDS];
    assign out_valid = v[ROUNDS];
endmodule

`default_nettype wire
