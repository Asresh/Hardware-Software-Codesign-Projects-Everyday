// ============================================================================
// as_divide.v - fully-pipelined unsigned restoring divider, quot = num / den.
//
// One quotient bit per pipeline slot, MSB first, WN slots total.  Retires one
// quotient per clock at a fixed latency of WN cycles, with a PAYW-bit payload
// carried alongside.  The caller applies the sign and saturation; here the
// division is pure unsigned so truncation is toward zero, matching the C
// golden's magnitude divide.  den==0 yields an all-ones quotient (guarded
// upstream, where den is the std and a zero std forces z=0 before this unit).
// ============================================================================
`default_nettype none

module as_divide #(
    parameter integer WN   = 48,     // numerator / quotient width
    parameter integer WD   = 32,     // denominator width
    parameter integer PAYW = 8
)(
    input  wire              clk,
    input  wire              en,
    input  wire              in_valid,
    input  wire [WN-1:0]     in_num,
    input  wire [WD-1:0]     in_den,
    input  wire [PAYW-1:0]   in_pay,
    output wire              out_valid,
    output wire [WN-1:0]     out_quot,
    output wire [PAYW-1:0]   out_pay
);
    localparam integer WR = WD + 2;  // remainder headroom

    reg [WN-1:0]   num  [0:WN];
    reg [WD-1:0]   den  [0:WN];
    reg [WN-1:0]   quot [0:WN];
    reg [WR-1:0]   rem  [0:WN];
    reg [PAYW-1:0] pay  [0:WN];
    reg            vld  [0:WN];

    always @(posedge clk) if (en) begin
        num[0]  <= in_num;
        den[0]  <= in_den;
        quot[0] <= {WN{1'b0}};
        rem[0]  <= {WR{1'b0}};
        pay[0]  <= in_pay;
        vld[0]  <= in_valid;
    end

    genvar i;
    generate
        for (i = 0; i < WN; i = i + 1) begin : g_stage
            localparam integer BITPOS = WN-1 - i;               // MSB first
            wire [WR-1:0] shifted = (rem[i] << 1) | num[i][BITPOS];
            wire          ge      = (shifted >= {{(WR-WD){1'b0}}, den[i]});
            wire [WR-1:0] sub     = shifted - {{(WR-WD){1'b0}}, den[i]};
            always @(posedge clk) if (en) begin
                rem[i+1]  <= ge ? sub : shifted;
                quot[i+1] <= ge ? (quot[i] | ({{(WN-1){1'b0}},1'b1} << BITPOS)) : quot[i];
                num[i+1]  <= num[i];
                den[i+1]  <= den[i];
                pay[i+1]  <= pay[i];
                vld[i+1]  <= vld[i];
            end
        end
    endgenerate

    assign out_valid = vld[WN];
    assign out_quot  = quot[WN];
    assign out_pay   = pay[WN];
endmodule

`default_nettype wire
