// -----------------------------------------------------------------------------
// rng_sequencer.v
// The engine's control core. On a doorbell it walks the requested draw range as
// a stream of "beats": each beat feeds LANES fresh counters (base+0 .. base+L-1)
// into the SIMD lane array on one clock, and LANES draws' worth of random words
// retire ROUNDS clocks later. The base counter advances by LANES per beat with a
// full 128-bit carry chain, so a job can span 32-bit counter-word wraps exactly
// like the software reference.
//
// A per-beat context {write address, per-lane valid mask} is pushed into a
// ROUNDS-deep delay line that is clocked in lockstep with the lane pipelines, so
// when a beat's random words emerge the matching write address and partial-beat
// mask emerge with them - no tags threaded through the datapath. The write bus
// is driven combinationally from the emerging context so it aligns exactly with
// the combinational lane outputs. Completion is detected when every issued beat
// has retired; the elapsed cycle count is latched for the host.
// -----------------------------------------------------------------------------
`default_nettype none

module rng_sequencer #(
    parameter integer LANES      = 4,
    parameter integer ROUNDS     = 10,
    parameter integer ADDR_WIDTH = 20
) (
    input  wire                    clk,
    input  wire                    rst_n,

    // job launch (descriptor is stable when start pulses)
    input  wire                    start,
    input  wire [31:0]             dst,
    input  wire [31:0]             ndraws,
    input  wire [127:0]            base_ctr_in,

    // to the lane array
    output wire                    issue_valid,
    output wire [LANES*128-1:0]    lane_in_ctr,

    // from the lane array (concatenated per-lane outputs)
    input  wire [LANES*128-1:0]    lane_out_ctr,

    // to the write master (combinational, aligned with lane_out_ctr)
    output wire                    wr_en,
    output wire [ADDR_WIDTH-1:0]   wr_addr,
    output wire [LANES-1:0]        wr_lmask,
    output wire [LANES*128-1:0]    wr_data,

    // status
    output reg                     busy,
    output reg                     done_pulse,
    output reg  [31:0]             cycles
);
    localparam integer WPB = LANES * 4;   // 32-bit words per beat

    // ---------------- issue-side state ----------------
    reg                   running;
    reg  [127:0]          base_ctr;
    reg  [31:0]           beats_left;
    reg  [31:0]           draws_left;
    reg  [31:0]           total_beats;
    reg  [31:0]           retired;
    reg  [ADDR_WIDTH-1:0] issue_addr;
    reg  [31:0]           cyc;

    wire issuing = running & (beats_left != 32'd0);
    assign issue_valid = issuing;

    // lane l gets base_ctr + l via a 128-bit carry chain (l is a constant)
    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : gen_lanes
            wire [32:0] a0 = {1'b0, base_ctr[31:0]}   + l[31:0];
            wire [32:0] a1 = {1'b0, base_ctr[63:32]}  + {31'd0, a0[32]};
            wire [32:0] a2 = {1'b0, base_ctr[95:64]}  + {31'd0, a1[32]};
            wire [31:0] a3 =        base_ctr[127:96]  + {31'd0, a2[32]};
            assign lane_in_ctr[l*128 +: 128] =
                { a3, a2[31:0], a1[31:0], a0[31:0] };
        end
    endgenerate
    assign wr_data = lane_out_ctr;

    // next base = base_ctr + LANES (128-bit carry chain)
    wire [32:0] nb0 = {1'b0, base_ctr[31:0]}  + LANES[31:0];
    wire [32:0] nb1 = {1'b0, base_ctr[63:32]} + {31'd0, nb0[32]};
    wire [32:0] nb2 = {1'b0, base_ctr[95:64]} + {31'd0, nb1[32]};
    wire [31:0] nb3 =        base_ctr[127:96] + {31'd0, nb2[32]};
    wire [127:0] base_next = { nb3, nb2[31:0], nb1[31:0], nb0[31:0] };

    // ---------------- per-beat context delay line (aligned with lanes) --------
    // stage 0 loads at issue; stage ROUNDS-1 emerges with the lane outputs.
    reg                   ctx_v    [0:ROUNDS-1];
    reg  [ADDR_WIDTH-1:0] ctx_addr [0:ROUNDS-1];
    reg  [LANES-1:0]      ctx_mask [0:ROUNDS-1];

    // this beat's per-lane valid mask (only the final beat is ever partial)
    reg [LANES-1:0] beat_mask;
    integer m;
    always @(*) begin
        for (m = 0; m < LANES; m = m + 1)
            beat_mask[m] = (m[31:0] < draws_left) ? 1'b1 : 1'b0;
    end

    // emerging beat drives the write bus combinationally
    assign wr_en    = running & ctx_v[ROUNDS-1];
    assign wr_addr  = ctx_addr[ROUNDS-1];
    assign wr_lmask = ctx_mask[ROUNDS-1];
    wire   emerge   = ctx_v[ROUNDS-1];

    integer s;
    always @(posedge clk) begin
        if (!rst_n) begin
            running <= 1'b0; busy <= 1'b0; done_pulse <= 1'b0;
            beats_left <= 32'd0; draws_left <= 32'd0; total_beats <= 32'd0;
            retired <= 32'd0; base_ctr <= 128'd0; issue_addr <= {ADDR_WIDTH{1'b0}};
            cyc <= 32'd0; cycles <= 32'd0;
            for (s = 0; s < ROUNDS; s = s + 1) begin
                ctx_v[s] <= 1'b0; ctx_addr[s] <= {ADDR_WIDTH{1'b0}};
                ctx_mask[s] <= {LANES{1'b0}};
            end
        end else begin
            done_pulse <= 1'b0;

            if (start && !running) begin
                // latch the descriptor and prime the walk
                base_ctr    <= base_ctr_in;
                draws_left  <= ndraws;
                total_beats <= (ndraws + LANES - 1) / LANES;
                beats_left  <= (ndraws + LANES - 1) / LANES;
                issue_addr  <= dst[ADDR_WIDTH-1:0];
                retired     <= 32'd0;
                cyc         <= 32'd0;
                running     <= 1'b1;
                busy        <= 1'b1;
            end else if (running) begin
                cyc <= cyc + 32'd1;

                // ---- issue side: push one beat when work remains ----
                if (issuing) begin
                    ctx_v[0]    <= 1'b1;
                    ctx_addr[0] <= issue_addr;
                    ctx_mask[0] <= beat_mask;
                    base_ctr    <= base_next;
                    issue_addr  <= issue_addr + WPB[ADDR_WIDTH-1:0];
                    beats_left  <= beats_left - 32'd1;
                    draws_left  <= (draws_left > LANES) ?
                                   (draws_left - LANES) : 32'd0;
                end else begin
                    ctx_v[0]    <= 1'b0;
                end

                // ---- context delay line shift ----
                for (s = 1; s < ROUNDS; s = s + 1) begin
                    ctx_v[s]    <= ctx_v[s-1];
                    ctx_addr[s] <= ctx_addr[s-1];
                    ctx_mask[s] <= ctx_mask[s-1];
                end

                // ---- retire side + completion ----
                if (emerge)
                    retired <= retired + 32'd1;

                if ((beats_left == 32'd0) &&
                    ((retired + (emerge ? 32'd1 : 32'd0)) == total_beats)) begin
                    running    <= 1'b0;
                    busy       <= 1'b0;
                    done_pulse <= 1'b1;
                    cycles     <= cyc + 32'd1;
                end
            end
        end
    end
endmodule

`default_nettype wire
