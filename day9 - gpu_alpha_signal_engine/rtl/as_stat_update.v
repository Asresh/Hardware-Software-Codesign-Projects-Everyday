// ============================================================================
// as_stat_update.v - combinational per-symbol EWMA / variance update.
//
// Given a symbol's current streaming state and a new tick price, produce the
// next state (fast EWMA, slow EWMA, variance = EWMA of squared deviation, tick
// count) plus the two derived quantities the signal pipeline needs: the
// deviation from the updated slow EWMA and the fast/slow momentum.
//
// All arithmetic is Q16.16 two's-complement on 64-bit intermediates, matched
// exactly to asig_step() in the C golden.  The first tick of a symbol (count
// == 0) seeds both EWMAs with the price and leaves variance at zero, avoiding a
// cold-start transient.  Being purely combinational, it closes a single-cycle
// read-modify-write on the symbol RAM, so back-to-back ticks on the same symbol
// stream at one tick per clock with no stale-state hazard.
// ============================================================================
`default_nettype none

module as_stat_update #(
    parameter integer FRAC   = 16,
    parameter integer EWW    = 32,   // EWMA word width (Q16.16, bounded)
    parameter integer VARW   = 48    // variance word width (Q16.16, >= 0)
)(
    input  wire signed [31:0]      price,     // Q16.16
    input  wire signed [EWW-1:0]   ef_in,
    input  wire signed [EWW-1:0]   es_in,
    input  wire        [VARW-1:0]  var_in,
    input  wire        [31:0]      cnt_in,
    input  wire        [31:0]      alpha,     // Q0.16
    input  wire        [31:0]      beta,
    input  wire        [31:0]      gamma,
    output wire signed [EWW-1:0]   ef_out,
    output wire signed [EWW-1:0]   es_out,
    output wire        [VARW-1:0]  var_out,
    output wire        [31:0]      cnt_out,
    output wire signed [31:0]      dev_out,   // price - es_out, Q16.16
    output wire signed [31:0]      mom_out    // ef_out - es_out, Q16.16
);
    wire seed = (cnt_in == 32'd0);

    wire signed [63:0] x   = {{32{price[31]}}, price};
    wire signed [63:0] ef  = {{(64-EWW){ef_in[EWW-1]}}, ef_in};
    wire signed [63:0] es  = {{(64-EWW){es_in[EWW-1]}}, es_in};
    wire signed [63:0] va  = {{(64-VARW){1'b0}}, var_in};   // variance >= 0
    wire signed [63:0] al  = {32'd0, alpha};
    wire signed [63:0] be  = {32'd0, beta};
    wire signed [63:0] ga  = {32'd0, gamma};

    // fast / slow EWMA: e += ((x - e) * w) >>> FRAC
    wire signed [63:0] df   = x - ef;
    wire signed [63:0] ef_u = ef + ((df * al) >>> FRAC);
    wire signed [63:0] ds   = x - es;
    wire signed [63:0] es_u = es + ((ds * be) >>> FRAC);

    // deviation vs updated slow EWMA, squared, then variance EWMA
    wire signed [63:0] d   = x - es_u;
    wire signed [63:0] d2  = (d * d) >>> FRAC;
    wire signed [63:0] va_u = va + (((d2 - va) * ga) >>> FRAC);

    assign ef_out  = seed ? price : ef_u[EWW-1:0];
    assign es_out  = seed ? price : es_u[EWW-1:0];
    assign var_out = seed ? {VARW{1'b0}} : va_u[VARW-1:0];
    assign cnt_out = seed ? 32'd1 : (cnt_in == 32'hFFFFFFFF ? cnt_in : cnt_in + 32'd1);

    // dev/mom reflect the post-update state (for seed: es_out==price -> dev 0)
    wire signed [63:0] es_final = seed ? x : es_u;
    wire signed [63:0] ef_final = seed ? x : ef_u;
    assign dev_out = (x - es_final);
    assign mom_out = (ef_final - es_final);
endmodule

`default_nettype wire
