// ============================================================================
// as_isqrt.v - fully-pipelined integer square root, root = floor(sqrt(x)).
//
// Digit-by-digit ("Dijkstra") square root unrolled into STAGES pipeline slots,
// one test bit per slot starting at 1<<62.  Retires one result per clock at a
// fixed latency of STAGES cycles; a PAYW-bit payload rides alongside so the
// caller can realign per-request metadata with the root.  The C golden
// (asig_isqrt) mirrors this loop bit-for-bit.
// ============================================================================
`default_nettype none

module as_isqrt #(
    parameter integer STAGES = 32,   // covers inputs up to 1<<63
    parameter integer PAYW   = 8
)(
    input  wire              clk,
    input  wire              en,      // pipeline advance / clock-enable
    input  wire              in_valid,
    input  wire [63:0]       in_x,
    input  wire [PAYW-1:0]   in_pay,
    output wire              out_valid,
    output wire [31:0]       out_root,
    output wire [PAYW-1:0]   out_pay
);
    // per-stage registers
    reg [63:0]     x   [0:STAGES];
    reg [63:0]     res [0:STAGES];
    reg [PAYW-1:0] pay [0:STAGES];
    reg            vld [0:STAGES];

    // stage 0 = registered input
    always @(posedge clk) if (en) begin
        x[0]   <= in_x;
        res[0] <= 64'd0;
        pay[0] <= in_pay;
        vld[0] <= in_valid;
    end

    genvar i;
    generate
        for (i = 0; i < STAGES; i = i + 1) begin : g_stage
            // test bit for this stage: 1 << (62 - 2*i)
            localparam integer SH = 62 - 2*i;
            wire [63:0] bit_i = (SH >= 0) ? (64'd1 << SH) : 64'd0;
            wire [63:0] rb    = res[i] + bit_i;
            wire        ge    = (x[i] >= rb);
            always @(posedge clk) if (en) begin
                x[i+1]   <= ge ? (x[i] - rb)          : x[i];
                res[i+1] <= ge ? ((res[i] >> 1) + bit_i) : (res[i] >> 1);
                pay[i+1] <= pay[i];
                vld[i+1] <= vld[i];
            end
        end
    endgenerate

    assign out_valid = vld[STAGES];
    assign out_root  = res[STAGES][31:0];
    assign out_pay   = pay[STAGES];
endmodule

`default_nettype wire
