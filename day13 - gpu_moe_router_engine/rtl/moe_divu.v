// ============================================================================
// moe_divu.v - fully-pipelined unsigned restoring divider.
//
// Computes quo = floor(num / den) with one result per clock and a fixed
// latency of (NUMW+1) cycles.  Used to renormalise the softmax exp values to
// Q.16 gate weights: num = exp << 16, den = sum of the selected exps.  The
// bit-serial restoring recurrence is spatially unrolled into NUMW pipeline
// stages so a new division can be issued every cycle when `en` is high.
//
// `en` is the global pipeline advance; when it is low every stage freezes,
// so the divider stalls losslessly with the rest of the datapath.
// ============================================================================
`default_nettype none

module moe_divu #(
    parameter integer NUMW = 34,   // numerator width (>= exp_w + FRAC)
    parameter integer DIVW = 18    // divisor width
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             en,        // pipeline advance / clock-enable
    input  wire             in_valid,
    input  wire [NUMW-1:0]  num,
    input  wire [DIVW-1:0]  den,
    output wire             out_valid,
    output wire [NUMW-1:0]  quo
);
    reg              vv [0:NUMW];
    reg [NUMW-1:0]   qq [0:NUMW];   // quotient accumulator
    reg [DIVW:0]     rr [0:NUMW];   // running remainder (DIVW+1 bits)
    reg [NUMW-1:0]   nn [0:NUMW];   // remaining numerator, MSB-aligned
    reg [DIVW-1:0]   dd [0:NUMW];   // divisor carried down the pipe

    reg [DIVW:0] tsh;               // shifted remainder | next numerator bit
    integer s;

    always @(posedge clk) begin
        if (!rst_n) begin
            // only the valid chain must reset; data stages are gated by valid
            for (s = 0; s <= NUMW; s = s + 1) vv[s] <= 1'b0;
        end else if (en) begin
            // ---- stage 0 : load a fresh division ----
            vv[0] <= in_valid;
            qq[0] <= {NUMW{1'b0}};
            rr[0] <= {(DIVW+1){1'b0}};
            nn[0] <= num;
            dd[0] <= den;
            // ---- stages 1..NUMW : one restoring step each ----
            for (s = 0; s < NUMW; s = s + 1) begin
                tsh = {rr[s][DIVW-1:0], nn[s][NUMW-1]};
                if (tsh >= {1'b0, dd[s]}) begin
                    rr[s+1] <= tsh - {1'b0, dd[s]};
                    qq[s+1] <= {qq[s][NUMW-2:0], 1'b1};
                end else begin
                    rr[s+1] <= tsh;
                    qq[s+1] <= {qq[s][NUMW-2:0], 1'b0};
                end
                nn[s+1] <= {nn[s][NUMW-2:0], 1'b0};
                dd[s+1] <= dd[s];
                vv[s+1] <= vv[s];
            end
        end
    end

    assign out_valid = vv[NUMW];
    assign quo       = qq[NUMW];
endmodule

`default_nettype wire
