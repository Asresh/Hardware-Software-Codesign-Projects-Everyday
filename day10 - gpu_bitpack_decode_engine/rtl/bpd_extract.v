// ============================================================================
// bpd_extract.v  -  wide barrel-shift field extractor (combinational)
//
// Pulls LANES fixed-width unsigned fields out of the reader window in one shot.
// Field i lives at bit offset i*width (LSB-first packing), so the extractor is
// LANES parallel barrel shifters + masks - the datapath that turns a
// variable-rate packed stream into LANES aligned residuals per clock.
//
//   width == 0  -> every residual is 0 (constant/RLE run, deltas all zero)
//   width == 32 -> full-word field, mask is all ones
// ============================================================================
`default_nettype none

module bpd_extract #(
    parameter integer LANES  = 4,
    parameter integer DATA_W = 32,
    parameter integer WINW   = 128
) (
    input  wire [WINW-1:0]           window,
    input  wire [5:0]                width,
    output wire [LANES*DATA_W-1:0]   res_flat
);
    wire [DATA_W-1:0] mask = (width == 6'd0)  ? {DATA_W{1'b0}} :
                             (width >= 6'd32) ? {DATA_W{1'b1}} :
                                                ((32'd1 << width) - 32'd1);

    genvar i;
    generate
        for (i = 0; i < LANES; i = i + 1) begin : g_lane
            // offset = i*width, up to (LANES-1)*32 = 96 for LANES=4
            wire [8:0]        off  = i[8:0] * {3'b0, width};
            wire [WINW-1:0]   shft = window >> off;
            assign res_flat[i*DATA_W +: DATA_W] = shft[DATA_W-1:0] & mask;
        end
    endgenerate
endmodule

`default_nettype wire
