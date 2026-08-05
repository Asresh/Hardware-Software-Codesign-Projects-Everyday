// ============================================================================
// emb_divu - fully pipelined signed / unsigned restoring divider.
//
// Used only by MEAN pooling: quotient = sum / count, truncated toward zero, i.e.
// exactly C99 `int32_t / int32_t` semantics, so the golden model's plain `/` and
// this divider agree bit for bit including the negative cases (-7/2 == -3).
//
// The dividend is signed and the divisor is the (always positive) count of
// locally pooled rows, so the quotient's sign is the dividend's sign and the
// magnitude division is unsigned.  Taking the magnitude as an unsigned 32-bit
// value means INT32_MIN maps to 0x80000000 and divides correctly rather than
// overflowing.
//
// One result per clock, LAT = W + 2 cycles of latency, with a tag carried
// alongside so the caller can write each quotient back to the element position
// it came from without tracking the pipeline depth itself.
// ============================================================================
module emb_divu #(
    parameter W    = 32,
    parameter TAGW = 8
) (
    input  wire               clk,
    input  wire               rst,

    input  wire               in_valid,
    input  wire signed [W-1:0] in_num,
    input  wire        [W-1:0] in_den,   // must be non-zero
    input  wire [TAGW-1:0]     in_tag,

    output wire                out_valid,
    output wire signed [W-1:0] out_q,
    output wire [TAGW-1:0]     out_tag
);
    localparam integer LAT = W + 2;

    // stage 0 registers the operands; stages 1..W do one restoring step each;
    // stage W+1 applies the sign.
    reg              v   [0:LAT-1];
    reg [TAGW-1:0]   tg  [0:LAT-1];
    reg              sgn [0:LAT-1];
    reg [W-1:0]      a   [0:LAT-1];   // remaining dividend magnitude bits
    reg [W-1:0]      d   [0:LAT-1];   // divisor
    reg [W-1:0]      q   [0:LAT-1];   // quotient so far
    reg [W:0]        r   [0:LAT-1];   // running remainder (one extra bit)

    wire [W-1:0] mag = in_num[W-1] ? (~in_num + {{(W-1){1'b0}}, 1'b1})
                                   : in_num[W-1:0];

    integer s;
    reg [W:0] rsh;

    always @(posedge clk) begin
        if (rst) begin
            for (s = 0; s < LAT; s = s + 1) v[s] <= 1'b0;
        end else begin
            // ---- stage 0: capture ----
            v[0]   <= in_valid;
            tg[0]  <= in_tag;
            sgn[0] <= in_num[W-1];
            a[0]   <= mag;
            d[0]   <= in_den;
            q[0]   <= {W{1'b0}};
            r[0]   <= {(W+1){1'b0}};

            // ---- stages 1..W: one restoring division step per stage ----
            for (s = 1; s <= W; s = s + 1) begin
                rsh = {r[s-1][W-1:0], a[s-1][W-1]};   // shift in the next MSB
                v[s]   <= v[s-1];
                tg[s]  <= tg[s-1];
                sgn[s] <= sgn[s-1];
                d[s]   <= d[s-1];
                a[s]   <= {a[s-1][W-2:0], 1'b0};
                if (rsh >= {1'b0, d[s-1]}) begin
                    r[s] <= rsh - {1'b0, d[s-1]};
                    q[s] <= {q[s-1][W-2:0], 1'b1};
                end else begin
                    r[s] <= rsh;
                    q[s] <= {q[s-1][W-2:0], 1'b0};
                end
            end

            // ---- stage W+1: sign fix ----
            v[W+1]   <= v[W];
            tg[W+1]  <= tg[W];
            sgn[W+1] <= sgn[W];
            q[W+1]   <= sgn[W] ? (~q[W] + {{(W-1){1'b0}}, 1'b1}) : q[W];
        end
    end

    assign out_valid = v[LAT-1];
    assign out_q     = q[LAT-1];
    assign out_tag   = tg[LAT-1];
endmodule
