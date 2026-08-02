// ============================================================================
// moe_softmax.v - fixed-point softmax numerators over the selected experts.
//
// Given the top-0 (max) and top-1 logits it produces the exp() numerators and
// their sum for the K=2 selected experts, in Q.16.  exp(top0-max)=exp(0)=1.0
// is the LUT origin; exp(top1-max) uses a piecewise-linear interpolation of a
// 257-entry table (exp(-i/16), i in [0,256]) that the software writes to
// exp_lut.hex - so the hardware evaluates the identical integer arithmetic as
// the golden model.  Beyond |d| = 16.0 the exp underflows and is clamped to 0.
//
// Outputs num0/num1 = exp << 16 (dividend for the renormalising divider) and
// den = exp0 + exp1 (divisor).  Purely combinational.
// ============================================================================
`default_nettype none

module moe_softmax #(
    parameter integer LW   = 16,
    parameter integer EXPW = 18,    // exp value width (holds 0x10000 == 1.0)
    parameter integer NUMW = 34,    // = EXPW + 16 dividend width
    parameter integer DIVW = 18,    // divisor width
    parameter integer LUTN = 257
) (
    input  wire signed [LW-1:0] top0_val,   // maximum logit
    input  wire signed [LW-1:0] top1_val,
    output wire [NUMW-1:0]      num0,        // exp0 << 16
    output wire [NUMW-1:0]      num1,        // exp1 << 16
    output wire [DIVW-1:0]      den          // exp0 + exp1
);
    (* rom_style = "block" *)
    reg [EXPW-1:0] lut [0:LUTN-1];
    initial $readmemh("exp_lut.hex", lut);

    // ---- exp0 = exp(0) = LUT origin (== 1.0 in Q.16) ----
    wire [EXPW-1:0] exp0 = lut[0];

    // ---- exp1 = exp(top1 - top0) via piecewise-linear interpolation ----
    wire signed [16:0] diff = $signed(top0_val) - $signed(top1_val); // >= 0
    wire [16:0]        a    = diff[16:0];        // |d| in Q8.8, >= 0
    wire               clip = (a >= 17'd4096);   // |d| >= 16.0 -> exp ~ 0
    wire [7:0]         idx  = a[11:4];
    wire [3:0]         frac = a[3:0];
    wire [EXPW-1:0]    base = lut[idx];
    wire [EXPW-1:0]    nxt  = lut[idx + 1];
    wire [EXPW-1:0]    delta = base - nxt;        // >= 0 (monotone decreasing)
    wire [EXPW+3:0]    prod = delta * frac;
    wire [EXPW-1:0]    interp = base - (prod >> 4);
    wire [EXPW-1:0]    exp1 = clip ? {EXPW{1'b0}} : interp;

    assign num0 = {exp0, 16'b0};
    assign num1 = {exp1, 16'b0};
    assign den  = exp0 + exp1;
endmodule

`default_nettype wire
