// ===========================================================================
// sdv_argmax_tree.v - log-depth argmax reduction over a dynamically masked
//                     candidate set.
//
// Reduces N {valid, key, index} triples to the single valid entry with the
// largest key, ties broken towards the lowest index, in ceil(log2(N)) levels
// of two-input merges.  Both properties come out of one merge rule: a right
// child only displaces a left child when it is valid and strictly greater, and
// because leaf i is seeded with index i the left subtree always holds the
// lower indices.  The tie-break is therefore structural rather than a
// comparison, which is what makes the selected path a pure function of the
// tree and not of the order the nodes happened to be numbered in.
//
// This is the block that replaces the CPU's inner loop: the host has to sweep
// every node once per path step to find the best acceptable child; here all N
// candidates are compared against each other in one cycle.
// ===========================================================================
`default_nettype none

module sdv_argmax_tree #(
    parameter integer N  = 64,
    parameter integer W  = 16,          // key width
    parameter integer IW = 6            // index width, clog2(N)
)(
    input  wire [N-1:0]     valid,
    input  wire [N*W-1:0]   key,
    output wire             any,
    output wire [IW-1:0]    idx,
    output wire [W-1:0]     val
);
    // pad up to a power of two so every level is a clean halving
    localparam integer L  = (N <= 1)   ?  0 : (N <= 2)   ? 1 : (N <= 4)   ? 2 :
                            (N <= 8)   ?  3 : (N <= 16)  ? 4 : (N <= 32)  ? 5 :
                            (N <= 64)  ?  6 : (N <= 128) ? 7 : (N <= 256) ? 8 :
                            (N <= 512) ?  9 : 10;
    localparam integer NP = (1 << L);

    reg           tv [0:L][0:NP-1];
    reg [W-1:0]   tk [0:L][0:NP-1];
    reg [IW-1:0]  ti [0:L][0:NP-1];

    integer l, i, a, b;
    reg take_right;

    always @* begin
        // level 0: the leaves, padded entries permanently invalid
        for (i = 0; i < NP; i = i + 1) begin
            if (i < N) begin
                tv[0][i] = valid[i];
                tk[0][i] = key[i*W +: W];
            end else begin
                tv[0][i] = 1'b0;
                tk[0][i] = {W{1'b0}};
            end
            ti[0][i] = i[IW-1:0];
        end

        // levels 1..L: pairwise merge, keep the larger key, ties to the left
        for (l = 1; l <= L; l = l + 1) begin
            for (i = 0; i < NP; i = i + 1) begin
                tv[l][i] = 1'b0;
                tk[l][i] = {W{1'b0}};
                ti[l][i] = {IW{1'b0}};
            end
            for (i = 0; i < (NP >> l); i = i + 1) begin
                a = 2*i;
                b = 2*i + 1;
                take_right = tv[l-1][b] &&
                             (!tv[l-1][a] || (tk[l-1][b] > tk[l-1][a]));
                if (take_right) begin
                    tv[l][i] = tv[l-1][b];
                    tk[l][i] = tk[l-1][b];
                    ti[l][i] = ti[l-1][b];
                end else begin
                    tv[l][i] = tv[l-1][a];
                    tk[l][i] = tk[l-1][a];
                    ti[l][i] = ti[l-1][a];
                end
            end
        end
    end

    assign any = tv[L][0];
    assign idx = ti[L][0];
    assign val = tk[L][0];

endmodule
`default_nettype wire
