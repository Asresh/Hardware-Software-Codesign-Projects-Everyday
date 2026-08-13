// -----------------------------------------------------------------------------
// philox_top.v
// GPU-style Philox-4x32-10 counter-based parallel RNG engine (top level).
//
//   host --MMIO--> philox_regfile --descriptor--> rng_sequencer
//                                                     |  issues LANES counters/clk
//                                                     v
//                          LANES x philox_lane  (fully-pipelined, ROUNDS deep)
//                                                     |  LANES random blocks/clk
//                                                     v
//                               wr_master --coalesced wide beat--> device memory
//
// The sequencer streams counters into a SIMD array of independent Philox lanes;
// LANES draws retire per clock in steady state (LANES*128 random bits/clock) and
// are packed into one wide masked memory write. A completion interrupt tells the
// host the stream is in memory. Everything is parameterized by LANES / ROUNDS /
// ADDR_WIDTH so the same source scales from one lane to a wide SIMD engine.
// -----------------------------------------------------------------------------
`default_nettype none

module philox_top #(
    parameter integer LANES      = 4,
    parameter integer ROUNDS     = 10,
    parameter integer ADDR_WIDTH = 20
) (
    input  wire                    clk,
    input  wire                    rst_n,

    // MMIO mailbox (slave)
    input  wire                    mmio_sel,
    input  wire                    mmio_write,
    input  wire [7:0]              mmio_addr,
    input  wire [31:0]             mmio_wdata,
    output wire [31:0]             mmio_rdata,

    // coalesced wide write master (to device memory)
    output wire                    mem_wr_en,
    output wire [ADDR_WIDTH-1:0]   mem_wr_addr,
    output wire [LANES*128-1:0]    mem_wr_data,
    output wire [LANES*4-1:0]      mem_wr_mask,

    output wire                    irq
);
    // ---- regfile <-> sequencer ----
    wire [31:0] dst, ndraws, key0, key1, ctr0, ctr1, ctr2, ctr3;
    wire        start, seq_busy, seq_done_pulse;
    wire [31:0] seq_cycles;

    philox_regfile #(.LANES(LANES)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .mmio_sel(mmio_sel), .mmio_write(mmio_write), .mmio_addr(mmio_addr),
        .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .dst(dst), .ndraws(ndraws), .key0(key0), .key1(key1),
        .ctr0(ctr0), .ctr1(ctr1), .ctr2(ctr2), .ctr3(ctr3), .start(start),
        .seq_busy(seq_busy), .seq_done_pulse(seq_done_pulse),
        .seq_cycles(seq_cycles), .irq(irq)
    );

    // ---- sequencer <-> lanes / write master ----
    wire                 issue_valid;
    wire [LANES*128-1:0] lane_in_ctr;
    wire [LANES*128-1:0] lane_out_ctr;
    wire                 wr_en;
    wire [ADDR_WIDTH-1:0] wr_addr;
    wire [LANES-1:0]     wr_lmask;
    wire [LANES*128-1:0] wr_data;

    rng_sequencer #(.LANES(LANES), .ROUNDS(ROUNDS), .ADDR_WIDTH(ADDR_WIDTH)) u_seq (
        .clk(clk), .rst_n(rst_n),
        .start(start), .dst(dst), .ndraws(ndraws),
        .base_ctr_in({ctr3, ctr2, ctr1, ctr0}),
        .issue_valid(issue_valid), .lane_in_ctr(lane_in_ctr),
        .lane_out_ctr(lane_out_ctr),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_lmask(wr_lmask), .wr_data(wr_data),
        .busy(seq_busy), .done_pulse(seq_done_pulse), .cycles(seq_cycles)
    );

    // ---- SIMD lane array: LANES independent Philox pipelines ----
    wire [63:0] job_key = {key1, key0};
    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : gen_lane
            philox_lane #(.ROUNDS(ROUNDS)) u_lane (
                .clk(clk), .rst_n(rst_n),
                .in_valid(issue_valid),
                .in_ctr(lane_in_ctr[l*128 +: 128]),
                .key(job_key),
                .out_valid(),                       // per-beat validity via ctx
                .out_ctr(lane_out_ctr[l*128 +: 128])
            );
        end
    endgenerate

    // ---- coalesced wide write master ----
    wr_master #(.LANES(LANES), .ADDR_WIDTH(ADDR_WIDTH)) u_wr (
        .beat_valid(wr_en), .beat_addr(wr_addr),
        .lane_mask(wr_lmask), .lane_data(wr_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data), .mem_wr_mask(mem_wr_mask)
    );
endmodule

`default_nettype wire
