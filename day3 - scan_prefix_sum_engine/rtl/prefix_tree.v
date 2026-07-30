// -----------------------------------------------------------------------------
// prefix_tree.v
// Kogge-Stone / Hillis-Steele parallel-prefix inclusive-scan network.
//
// This is the combinational heart of the engine: a LANES-wide adder tree that,
// in one pass, turns a tile of LANES words into their inclusive prefix sums.
// It is the same primitive a GPU runs across a warp (the "naive" work-inefficient
// scan of GPU Gems ch.39) unrolled fully into hardware: ceil(log2(LANES)) levels
// of LANES adders each. The block total (inclusive[LANES-1]) is exported so the
// controller can chain the running carry across successive tiles - exactly how a
// single-pass device-wide scan stitches per-block scans together.
//
// Pure combinational; the register that samples it lives in scan_datapath.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module prefix_tree #(
    parameter integer LANES = 16,   // words scanned in parallel (power of two)
    parameter integer W     = 32    // word width in bits
)(
    input  wire [LANES*W-1:0] din,        // LANES packed input words
    output wire [LANES*W-1:0] inclusive,  // inclusive prefix sums, packed
    output wire [W-1:0]       total        // sum of every lane (= inclusive[LANES-1])
);
    // ceil(log2(LANES)) - number of prefix levels
    function integer clog2;
        input integer value;
        integer i;
        begin
            clog2 = 0;
            for (i = value - 1; i > 0; i = i >> 1) clog2 = clog2 + 1;
        end
    endfunction
    localparam integer NST = clog2(LANES);

    // (NST+1) rows x LANES words of intermediate nodes, flattened to 1-D.
    // Row 0 = inputs; row NST = inclusive result.
    wire [W-1:0] node [0:(NST+1)*LANES-1];

    genvar s, i;
    generate
        // level 0: the inputs
        for (i = 0; i < LANES; i = i + 1) begin : g_in
            assign node[i] = din[i*W +: W];
        end
        // prefix levels: node[s][i] = node[s-1][i] + node[s-1][i-2^(s-1)]
        for (s = 1; s <= NST; s = s + 1) begin : g_stage
            localparam integer D = (1 << (s - 1));
            for (i = 0; i < LANES; i = i + 1) begin : g_lane
                if (i >= D)
                    assign node[s*LANES + i] =
                        node[(s-1)*LANES + i] + node[(s-1)*LANES + i - D];
                else
                    assign node[s*LANES + i] = node[(s-1)*LANES + i];
            end
        end
        // level NST: publish the inclusive scan
        for (i = 0; i < LANES; i = i + 1) begin : g_out
            assign inclusive[i*W +: W] = node[NST*LANES + i];
        end
    endgenerate

    assign total = node[NST*LANES + (LANES-1)];
endmodule

`default_nettype wire
