// ============================================================================
// bpd_decode.v  -  zig-zag + delta-prefix reconstruction (combinational)
//
// Turns LANES unsigned residuals into LANES reconstructed 32-bit values:
//
//   delta_i = zigzag_decode(res_i) = (res_i >> 1) ^ -(res_i & 1)   (signed)
//   value_i = carry_in + sum_{k=0..i} delta_k                       (mod 2^32)
//
// carry_in is the previously emitted value (v_-1 = block base). The small
// LANES-wide prefix chain runs combinationally so the running carry can be
// updated every clock, letting the engine retire one group per cycle without
// a feedback bubble. carry_out reflects the last *valid* lane given `take`.
// ============================================================================
`default_nettype none

module bpd_decode #(
    parameter integer LANES  = 4,
    parameter integer DATA_W = 32
) (
    input  wire [LANES*DATA_W-1:0]  res_flat,
    input  wire [2:0]               take,      // number of valid lanes (1..LANES)
    input  wire [DATA_W-1:0]        carry_in,
    output wire [LANES*DATA_W-1:0]  val_flat,
    output wire [DATA_W-1:0]        carry_out
);
    wire [DATA_W-1:0] res  [0:LANES-1];
    wire [DATA_W-1:0] dlt  [0:LANES-1]; // signed delta (two's complement)
    wire [DATA_W-1:0] pfx  [0:LANES-1]; // reconstructed value

    genvar i;
    generate
        for (i = 0; i < LANES; i = i + 1) begin : g_dec
            assign res[i] = res_flat[i*DATA_W +: DATA_W];
            // zig-zag decode: (u>>1) ^ -(u&1);  -(u&1) is all-ones when u is odd
            assign dlt[i] = (res[i] >> 1) ^ {DATA_W{res[i][0]}};
            if (i == 0)
                assign pfx[i] = carry_in + dlt[i];
            else
                assign pfx[i] = pfx[i-1] + dlt[i];
            assign val_flat[i*DATA_W +: DATA_W] = pfx[i];
        end
    endgenerate

    // carry_out = last valid lane's value
    assign carry_out = (take >= 3'd4) ? pfx[3] :
                       (take == 3'd3) ? pfx[2] :
                       (take == 3'd2) ? pfx[1] : pfx[0];
endmodule

`default_nettype wire
