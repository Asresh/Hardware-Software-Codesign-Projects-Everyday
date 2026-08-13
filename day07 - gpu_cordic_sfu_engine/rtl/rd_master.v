// -----------------------------------------------------------------------------
// rd_master.v
// The request-ring read master. Each active lane fetches one 4-word (128-bit)
// request entry from device memory in a single coalesced gather beat; per-lane
// addresses let a wave straddle the ring's wrap boundary without special-casing.
// The returned wide line is unpacked into the three request fields the decode
// needs - word 0 = op, word 1 = a, word 2 = b (word 3 reserved). The memory
// returns data one cycle after the address beat (a synchronous SRAM / DMA read),
// which the sequencer accounts for.
// -----------------------------------------------------------------------------
`default_nettype none

module rd_master #(
    parameter integer LANES      = 4,
    parameter integer ADDR_WIDTH = 20
) (
    input  wire                        beat_valid,
    input  wire [LANES*ADDR_WIDTH-1:0] lane_addr,
    input  wire [LANES-1:0]            lane_mask,

    // to device memory (gather read)
    output wire                        mem_rd_en,
    output wire [LANES*ADDR_WIDTH-1:0] mem_rd_addr,
    output wire [LANES-1:0]            mem_rd_mask,

    // returned wide line (registered by memory, valid next cycle)
    input  wire [LANES*128-1:0]        mem_rd_data,
    output wire [LANES*32-1:0]         req_op,
    output wire [LANES*32-1:0]         req_a,
    output wire [LANES*32-1:0]         req_b
);
    assign mem_rd_en   = beat_valid;
    assign mem_rd_addr = lane_addr;
    assign mem_rd_mask = lane_mask;

    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : gen_unpack
            assign req_op[l*32 +: 32] = mem_rd_data[l*128 + 0*32 +: 32];
            assign req_a [l*32 +: 32] = mem_rd_data[l*128 + 1*32 +: 32];
            assign req_b [l*32 +: 32] = mem_rd_data[l*128 + 2*32 +: 32];
        end
    endgenerate
endmodule

`default_nettype wire
