// -----------------------------------------------------------------------------
// bitonic_network.v
// Fully-pipelined Batcher bitonic sorting network over a tile of N keys.
//
// This is the combinational-per-stage heart of the accelerator, unrolled fully
// into hardware and pipelined so it retires one sorted N-key tile every clock.
// It is exactly the primitive a GPU runs to sort a block/warp of keys: Batcher's
// bitonic sort has a data-independent comparator schedule (no branches, no
// variable trip count), which is why it maps to SIMD lanes and to fixed silicon
// so well.
//
// Structure (classic index-based bitonic sort, N = 2^LOGN):
//
//   for k = 2, 4, ..., N            // size of the bitonic subsequence
//     for j = k/2, k/4, ..., 1      // compare distance within it
//       for each index i:           // N/2 compare-exchanges, all parallel
//         partner = i XOR j
//         direction ascending iff (i AND k) == 0
//
// Each (k,j) pair is one comparator STAGE of N/2 compare_exchange cells; there
// are LOGN*(LOGN+1)/2 stages. A pipeline register sits after every stage, so the
// network has that many pipeline slots and a steady-state throughput of one tile
// per clock. A per-tile direction bit (in_desc) rides alongside each tile in a
// shift register and flips every comparator, turning the ascending network into
// a descending sort with no extra hardware.
//
// Latency  = NSTAGES + 1 cycles (one input register + one register per stage).
// Throughput = 1 tile (N keys) per clock once full.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module bitonic_network #(
    parameter integer N = 16,       // keys per tile (power of two)
    parameter integer W = 32        // key width in bits
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              in_valid,          // a raw tile is presented this cycle
    input  wire              in_desc,           // 1 = sort descending, 0 = ascending
    input  wire [N*W-1:0]    in_data,           // N packed keys, index i at [i*W +: W]

    output wire              out_valid,          // sorted tile valid (LATENCY later)
    output wire [N*W-1:0]    out_data            // N packed keys, fully sorted
);
    function integer clog2;
        input integer value; integer i;
        begin clog2 = 0; for (i = value-1; i > 0; i = i >> 1) clog2 = clog2 + 1; end
    endfunction

    localparam integer LOGN    = clog2(N);
    localparam integer NSTAGES = (LOGN * (LOGN + 1)) / 2;   // comparator stages

    // Pipeline registers: (NSTAGES+1) rows of N keys. Row 0 is the input
    // register; row s (1..NSTAGES) holds the tile after comparator stage s-1.
    reg  [(NSTAGES+1)*N*W-1:0] preg;
    // Combinational next-stage values: NSTAGES rows of N keys.
    wire [NSTAGES*N*W-1:0]     nxt;
    // valid + direction travel with each tile through the pipeline.
    reg  [NSTAGES:0]           vpipe;
    reg  [NSTAGES:0]           mpipe;

    // ---- comparator network: one stage per (k,j), N/2 CAE cells per stage ----
    genvar gk, gj, gi;
    generate
        for (gk = 1; gk <= LOGN; gk = gk + 1) begin : g_outer     // k = 2^gk
            for (gj = gk - 1; gj >= 0; gj = gj - 1) begin : g_inner // j = 2^gj
                localparam integer K = (1 << gk);
                localparam integer J = (1 << gj);
                // flat stage index 0..NSTAGES-1 for this (k,j)
                localparam integer S = (gk * (gk - 1)) / 2 + (gk - 1 - gj);
                for (gi = 0; gi < N; gi = gi + 1) begin : g_lane
                    if ((gi & J) == 0) begin : g_pair
                        localparam integer PN       = gi + J;               // partner index
                        localparam integer BASE_ASC = ((gi & K) == 0) ? 1 : 0;
                        // per-tile direction flips the whole network for descending
                        wire asc = BASE_ASC[0] ^ mpipe[S];
                        compare_exchange #(.W(W)) u_cae (
                            .a  (preg[(S*N + gi)*W +: W]),
                            .b  (preg[(S*N + PN)*W +: W]),
                            .asc(asc),
                            .lo (nxt [(S*N + gi)*W +: W]),
                            .hi (nxt [(S*N + PN)*W +: W])
                        );
                    end
                end
            end
        end
    endgenerate

    // ---- pipeline: input register + one register after every stage ----
    integer s, i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            preg  <= {((NSTAGES+1)*N*W){1'b0}};
            vpipe <= {(NSTAGES+1){1'b0}};
            mpipe <= {(NSTAGES+1){1'b0}};
        end else begin
            // stage 0: register the incoming tile
            for (i = 0; i < N; i = i + 1)
                preg[(0*N + i)*W +: W] <= in_data[i*W +: W];
            vpipe[0] <= in_valid;
            mpipe[0] <= in_desc;

            // stages 1..NSTAGES: sample the comparator outputs of stage s
            for (s = 0; s < NSTAGES; s = s + 1) begin
                for (i = 0; i < N; i = i + 1)
                    preg[((s+1)*N + i)*W +: W] <= nxt[(s*N + i)*W +: W];
                vpipe[s+1] <= vpipe[s];
                mpipe[s+1] <= mpipe[s];
            end
        end
    end

    assign out_valid = vpipe[NSTAGES];
    genvar go;
    generate
        for (go = 0; go < N; go = go + 1) begin : g_out
            assign out_data[go*W +: W] = preg[(NSTAGES*N + go)*W +: W];
        end
    endgenerate
endmodule

`default_nettype wire
