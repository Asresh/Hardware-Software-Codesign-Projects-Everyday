// Author: Asresh
module kmer_hash_mix #(parameter WIDTH=32) (
    input wire [WIDTH-1:0] key,
    input wire [WIDTH-1:0] seed,
    output wire [WIDTH-1:0] hash
);
    wire [WIDTH-1:0] x0 = key ^ seed;
    wire [WIDTH-1:0] x1 = x0 ^ (x0 >> 16);
    wire [2*WIDTH-1:0] p = x1 * 32'h7feb352d;
    wire [WIDTH-1:0] x2 = p[WIDTH-1:0] ^ (p[WIDTH-1:0] >> 15);
    assign hash = x2;
endmodule
