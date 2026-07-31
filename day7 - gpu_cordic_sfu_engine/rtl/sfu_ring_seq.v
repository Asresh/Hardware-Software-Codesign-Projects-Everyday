// -----------------------------------------------------------------------------
// sfu_ring_seq.v
// The engine's control core: a ring-buffer consumer/producer that dispatches
// function requests to the SIMD CORDIC lane array. On a doorbell it walks COUNT
// requests from the submission ring starting at REQ_HEAD (wrapping modulo the
// ring capacity) in waves of LANES entries, and posts COUNT results to the
// completion ring starting at RES_HEAD (also wrapping). Per-lane addresses are
// generated so a wave can cross the ring's wrap point transparently.
//
// Per wave the FSM: (READ) issues one coalesced gather beat for up to LANES
// request entries; (RDWAIT) latches the returned {op,a,b}; (START) pulses every
// active lane's CORDIC core with the decoded initial vector; (COMPUTE) waits for
// each lane to retire - lanes take NC or NH cycles depending on the op, so the
// wave completes when the last one is done, capturing each result as it lands;
// (WRITE) posts one coalesced scatter beat of the LANES completion entries. The
// final wave's inactive lanes are masked off. Completion is raised when the last
// wave's results are in memory; the elapsed cycle count is latched for the host.
// -----------------------------------------------------------------------------
`default_nettype none

module sfu_ring_seq #(
    parameter integer LANES       = 4,
    parameter integer ADDR_WIDTH  = 20,
    parameter integer ENTRY_WORDS = 4,
    parameter         ROMFILE     = "tb/vectors/cordic_rom.hex"
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // job launch (descriptor stable when start pulses)
    input  wire                        start,
    input  wire [31:0]                 req_base,
    input  wire [31:0]                 res_base,
    input  wire [31:0]                 ring_cap,
    input  wire [31:0]                 req_head,
    input  wire [31:0]                 res_head,
    input  wire [31:0]                 count,

    // request-ring read master
    output wire                        rd_beat,
    output wire [LANES*ADDR_WIDTH-1:0] rd_addr,
    output wire [LANES-1:0]            rd_mask,
    input  wire [LANES*32-1:0]         req_op,
    input  wire [LANES*32-1:0]         req_a,
    input  wire [LANES*32-1:0]         req_b,

    // result-ring write master
    output wire                        wr_beat,
    output wire [LANES*ADDR_WIDTH-1:0] wr_addr,
    output wire [LANES-1:0]            wr_mask,
    output wire [LANES*32-1:0]         res_op,
    output wire [LANES*32-1:0]         res_r0,
    output wire [LANES*32-1:0]         res_r1,

    // status
    output reg                         busy,
    output reg                         done_pulse,
    output reg  [31:0]                 cycles
);
`include "sfu_const.vh"

    localparam [2:0] S_IDLE=3'd0, S_READ=3'd1, S_RDWAIT=3'd2, S_START=3'd3,
                     S_COMPUTE=3'd4, S_WRITE=3'd5, S_DONE=3'd6;

    reg  [2:0]  state;
    reg  [31:0] req_base_r, res_base_r, cap_mask, req_head_r, res_head_r, count_r;
    reg  [31:0] wbase;                 // global index of lane 0 this wave
    reg  [31:0] cyc;
    reg  [LANES-1:0] pend;             // lanes still computing this wave

    // per-lane latched request and captured result
    reg  [31:0] lane_op [0:LANES-1];
    reg  [31:0] lane_a  [0:LANES-1];
    reg  [31:0] lane_b  [0:LANES-1];
    reg  [31:0] lane_r0 [0:LANES-1];
    reg  [31:0] lane_r1 [0:LANES-1];

    reg  [LANES-1:0] core_start;

    // combinational per-lane geometry / lane pipes
    wire [LANES-1:0]            lane_active;
    wire [LANES*ADDR_WIDTH-1:0] lane_req_addr;
    wire [LANES*ADDR_WIDTH-1:0] lane_res_addr;
    wire [LANES-1:0]            lane_done;
    wire signed [31:0]          lane_cap_r0 [0:LANES-1];
    wire signed [31:0]          lane_cap_r1 [0:LANES-1];

    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : gen_lane
            // ---- ring addressing for this wave/lane ----
            wire [31:0] g    = wbase + l[31:0];
            wire [31:0] ridx = (req_head_r + g) & cap_mask;
            wire [31:0] sidx = (res_head_r + g) & cap_mask;
            wire [31:0] radr = req_base_r + ridx * ENTRY_WORDS;
            wire [31:0] sadr = res_base_r + sidx * ENTRY_WORDS;
            assign lane_active[l]                    = (g < count_r);
            assign lane_req_addr[l*ADDR_WIDTH +: ADDR_WIDTH] = radr[ADDR_WIDTH-1:0];
            assign lane_res_addr[l*ADDR_WIDTH +: ADDR_WIDTH] = sadr[ADDR_WIDTH-1:0];

            // ---- decode + CORDIC core ----
            wire               is_hyp, is_vec;
            wire signed [39:0] x0, y0, z0, xo, yo, zo;
            wire signed [31:0] dr0, dr1;
            wire               cbusy, cdone;

            sfu_decode u_dec (
                .op(lane_op[l][2:0]), .a(lane_a[l]), .b(lane_b[l]),
                .is_hyp(is_hyp), .is_vec(is_vec),
                .x0(x0), .y0(y0), .z0(z0),
                .xo(xo), .yo(yo), .zo(zo), .r0(dr0), .r1(dr1)
            );
            cordic_core #(.ROMFILE(ROMFILE)) u_core (
                .clk(clk), .rst_n(rst_n),
                .start(core_start[l]), .is_hyp(is_hyp), .is_vec(is_vec),
                .x0(x0), .y0(y0), .z0(z0),
                .busy(cbusy), .done(cdone), .xo(xo), .yo(yo), .zo(zo)
            );
            assign lane_done[l]   = cdone;
            assign lane_cap_r0[l] = dr0;
            assign lane_cap_r1[l] = dr1;

            // ---- result bus to the write master ----
            assign res_op[l*32 +: 32] = lane_op[l];
            assign res_r0[l*32 +: 32] = lane_r0[l];
            assign res_r1[l*32 +: 32] = lane_r1[l];
        end
    endgenerate

    // read/write master beats
    assign rd_beat = (state == S_READ);
    assign rd_addr = lane_req_addr;
    assign rd_mask = lane_active;
    assign wr_beat = (state == S_WRITE);
    assign wr_addr = lane_res_addr;
    assign wr_mask = lane_active;

    wire last_wave = (wbase + LANES[31:0]) >= count_r;

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; busy <= 1'b0; done_pulse <= 1'b0;
            cyc <= 32'd0; cycles <= 32'd0; wbase <= 32'd0; pend <= {LANES{1'b0}};
            core_start <= {LANES{1'b0}};
            req_base_r<=0; res_base_r<=0; cap_mask<=0;
            req_head_r<=0; res_head_r<=0; count_r<=0;
            for (i = 0; i < LANES; i = i + 1) begin
                lane_op[i]<=0; lane_a[i]<=0; lane_b[i]<=0;
                lane_r0[i]<=0; lane_r1[i]<=0;
            end
        end else begin
            done_pulse <= 1'b0;
            core_start <= {LANES{1'b0}};
            if (state != S_IDLE) cyc <= cyc + 32'd1;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        req_base_r <= req_base; res_base_r <= res_base;
                        cap_mask   <= ring_cap - 32'd1;
                        req_head_r <= req_head; res_head_r <= res_head;
                        count_r    <= count;
                        wbase      <= 32'd0;
                        cyc        <= 32'd0;
                        busy       <= 1'b1;
                        state      <= (count == 32'd0) ? S_DONE : S_READ;
                    end
                end

                S_READ:   state <= S_RDWAIT;          // read beat asserted

                S_RDWAIT: begin                        // latch returned request
                    for (i = 0; i < LANES; i = i + 1) begin
                        lane_op[i] <= req_op[i*32 +: 32];
                        lane_a [i] <= req_a [i*32 +: 32];
                        lane_b [i] <= req_b [i*32 +: 32];
                    end
                    state <= S_START;
                end

                S_START: begin                         // launch active lanes
                    core_start <= lane_active;
                    pend       <= lane_active;
                    state      <= S_COMPUTE;
                end

                S_COMPUTE: begin                       // capture each lane's result
                    for (i = 0; i < LANES; i = i + 1) begin
                        if (pend[i] && lane_done[i]) begin
                            lane_r0[i] <= lane_cap_r0[i];
                            lane_r1[i] <= lane_cap_r1[i];
                            pend[i]    <= 1'b0;
                        end
                    end
                    if ((pend & ~lane_done) == {LANES{1'b0}})
                        state <= S_WRITE;              // all lanes retired
                end

                S_WRITE: begin                         // scatter results, advance
                    if (last_wave) begin
                        state <= S_DONE;
                    end else begin
                        wbase <= wbase + LANES[31:0];
                        state <= S_READ;
                    end
                end

                S_DONE: begin
                    busy       <= 1'b0;
                    done_pulse <= 1'b1;
                    cycles     <= cyc + 32'd1;
                    state      <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
