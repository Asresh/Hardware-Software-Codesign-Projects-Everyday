// -----------------------------------------------------------------------------
// wr_master.v
// The coalesced wide write master. It packs the LANES retiring random blocks
// into one WORD_W-bit (LANES*128) memory beat and expands the per-lane valid
// mask into a per-32-bit-word write strobe, so a partial final beat writes only
// the words that correspond to real draws (an AXI-wstrb-style byte/word enable).
// Word (l*4 + j) of the beat is word j of lane l, little-endian - matching the
// dst + d*4 + j layout the software reference and golden vectors use.
// -----------------------------------------------------------------------------
`default_nettype none

module wr_master #(
    parameter integer LANES      = 4,
    parameter integer ADDR_WIDTH = 20
) (
    input  wire                    beat_valid,
    input  wire [ADDR_WIDTH-1:0]   beat_addr,
    input  wire [LANES-1:0]        lane_mask,
    input  wire [LANES*128-1:0]    lane_data,

    output wire                    mem_wr_en,
    output wire [ADDR_WIDTH-1:0]   mem_wr_addr,
    output wire [LANES*128-1:0]    mem_wr_data,
    output wire [LANES*4-1:0]      mem_wr_mask
);
    assign mem_wr_en   = beat_valid;
    assign mem_wr_addr = beat_addr;
    assign mem_wr_data = lane_data;

    // each valid lane enables its 4 consecutive 32-bit words
    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : gen_mask
            assign mem_wr_mask[l*4 +: 4] = {4{lane_mask[l]}};
        end
    endgenerate
endmodule

`default_nettype wire
