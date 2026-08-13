// ============================================================================
// ob_bbo_reduce - log-depth parallel reduction tree over the price levels.
//
// Reduces N candidate levels { valid, price, qty } to the single best one:
//   MODE = 0 (bid) -> the valid level with the MAXIMUM price
//   MODE = 1 (ask) -> the valid level with the MINIMUM price
// Levels are laid out as a binary heap (root = node[1]); each internal node is
// the better of its two children, so the whole selection is a balanced
// comparator tree of depth ceil(log2 N) rather than a linear O(N) scan. Prices
// are unique per side, so no tie-break policy is needed. Purely combinational.
// ============================================================================
`default_nettype none
module ob_bbo_reduce #(
    parameter integer PW   = 16,
    parameter integer QW   = 24,
    parameter integer N    = 32,
    parameter integer MODE = 0          // 0 = max (bid), 1 = min (ask)
) (
    input  wire [N-1:0]    in_valid,
    input  wire [N*PW-1:0] in_price,
    input  wire [N*QW-1:0] in_qty,
    output wire            out_valid,
    output wire [PW-1:0]   out_price,
    output wire [QW-1:0]   out_qty
);
    localparam integer NB   = 1 + PW + QW;             // packed node width
    localparam integer LOGN = (N <= 1) ? 1 : $clog2(N);
    localparam integer P    = (1 << LOGN);             // leaves, padded to pow2

    // node packing: { valid[NB-1], price[NB-2 -: PW], qty[QW-1:0] }
    wire [NB-1:0] node [0:2*P-1];

    genvar j;
    generate
        // ---- leaves ----
        for (j = 0; j < P; j = j + 1) begin : leaf
            if (j < N) begin : real_leaf
                assign node[P + j] = { in_valid[j],
                                       in_price[j*PW +: PW],
                                       in_qty  [j*QW +: QW] };
            end else begin : pad_leaf
                assign node[P + j] = {NB{1'b0}};        // invalid padding
            end
        end
        // ---- internal comparator nodes ----
        for (j = 1; j < P; j = j + 1) begin : inner
            wire            av = node[2*j][NB-1];
            wire            bv = node[2*j+1][NB-1];
            wire [PW-1:0]   ap = node[2*j][NB-2 -: PW];
            wire [PW-1:0]   bp = node[2*j+1][NB-2 -: PW];
            wire better_a = (MODE != 0) ? (ap <= bp) : (ap >= bp);
            // pick a when it is valid and (b invalid OR a is the better price)
            wire choose_a = av & (~bv | better_a);
            assign node[j] = choose_a ? node[2*j]
                                      : (bv ? node[2*j+1] : {NB{1'b0}});
        end
    endgenerate

    assign out_valid = node[1][NB-1];
    assign out_price = node[1][NB-2 -: PW];
    assign out_qty   = node[1][QW-1:0];
endmodule
`default_nettype wire
