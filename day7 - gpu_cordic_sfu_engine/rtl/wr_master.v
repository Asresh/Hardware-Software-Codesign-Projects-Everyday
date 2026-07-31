// -----------------------------------------------------------------------------
// wr_master.v
// The result-ring write master. It packs each lane's result {op, r0, r1} into a
// 4-word (128-bit) completion entry - word 3 reserved (zero) - and posts one
// coalesced scatter beat, with per-lane addresses so a partial final wave and a
// ring-wrap boundary both fall out naturally. The per-lane valid mask becomes
// the memory write-enable strobe, so inactive lanes of the final wave leave the
// ring untouched.
// -----------------------------------------------------------------------------
`default_nettype none

module wr_master #(
    parameter integer LANES      = 4,
    parameter integer ADDR_WIDTH = 20
) (
    input  wire                        beat_valid,
    input  wire [LANES*ADDR_WIDTH-1:0] lane_addr,
    input  wire [LANES-1:0]            lane_mask,
    input  wire [LANES*32-1:0]         res_op,
    input  wire [LANES*32-1:0]         res_r0,
    input  wire [LANES*32-1:0]         res_r1,

    // to device memory (scatter write)
    output wire                        mem_wr_en,
    output wire [LANES*ADDR_WIDTH-1:0] mem_wr_addr,
    output wire [LANES-1:0]            mem_wr_mask,
    output wire [LANES*128-1:0]        mem_wr_data
);
    assign mem_wr_en   = beat_valid;
    assign mem_wr_addr = lane_addr;
    assign mem_wr_mask = lane_mask;

    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : gen_pack
            assign mem_wr_data[l*128 + 0*32 +: 32] = res_op[l*32 +: 32];
            assign mem_wr_data[l*128 + 1*32 +: 32] = res_r0[l*32 +: 32];
            assign mem_wr_data[l*128 + 2*32 +: 32] = res_r1[l*32 +: 32];
            assign mem_wr_data[l*128 + 3*32 +: 32] = 32'd0;
        end
    endgenerate
endmodule

`default_nettype wire
