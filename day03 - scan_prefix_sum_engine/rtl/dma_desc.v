// -----------------------------------------------------------------------------
// dma_desc.v
// Descriptor-driven DMA controller + address generator for the scan engine.
//
// A descriptor is {SRC base, DST base, LEN elements, MODE}. On START the engine
// walks source memory in coalesced beats of LANES words (a 512-bit GPU-style
// wide access), streams each beat through the scan datapath, and writes the
// scanned beat back to destination memory - a single pass, no host round-trips.
//
// Steady state is one beat per clock through a three-stage pipeline:
//     read (comb addr-gen) -> scan (datapath, 1 reg) -> write (comb).
// A 1-cycle register (r1_*) aligns the descriptor bookkeeping with the memory's
// 1-cycle synchronous read latency. Beats retire in order, so a single write
// index reconstructs the destination address, and the short final tile is
// written with a reduced lane count. A counter measures the exact START->DONE
// latency reported through the CSR CYCLES register.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module dma_desc #(
    parameter integer LANES      = 16,
    parameter integer W          = 32,
    parameter integer ADDR_WIDTH = 20,   // word address space
    parameter integer LEN_WIDTH  = 20,
    parameter integer LANE_BITS  = 5     // holds 0..LANES
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- descriptor + control (from CSR block) ----
    input  wire                   start,      // 1-cycle pulse
    input  wire [ADDR_WIDTH-1:0]  src_addr,
    input  wire [ADDR_WIDTH-1:0]  dst_addr,
    input  wire [LEN_WIDTH-1:0]   len,
    input  wire                   mode_excl,

    output reg                    busy,
    output reg                    done,       // sticky until next start
    output reg  [31:0]            cycles,     // START->DONE latency of last job

    // ---- wide (coalesced) memory master ----
    output wire                   mem_rd_en,
    output wire [ADDR_WIDTH-1:0]  mem_rd_addr,
    input  wire [LANES*W-1:0]     mem_rd_data,  // valid 1 cycle after mem_rd_en

    output wire                   mem_wr_en,
    output wire [ADDR_WIDTH-1:0]  mem_wr_addr,
    output wire [LANE_BITS-1:0]   mem_wr_lanes, // valid lanes in this beat (1..LANES)
    output wire [LANES*W-1:0]     mem_wr_data,

    // ---- scan datapath handshake ----
    output reg                    clr_carry,
    output wire                   dp_mode_excl,
    output wire                   dp_in_valid,
    output wire [LANES*W-1:0]     dp_in_data,
    output wire [LANE_BITS-1:0]   dp_in_lanes,
    input  wire                   dp_out_valid,
    input  wire [LANES*W-1:0]     dp_out_data,
    input  wire [LANE_BITS-1:0]   dp_out_lanes
);
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;
    reg [1:0] state;

    reg [ADDR_WIDTH-1:0] src_q, dst_q;
    reg [LEN_WIDTH-1:0]  len_q;
    reg                  mode_q;
    reg [ADDR_WIDTH:0]   nbeats;     // ceil(len/LANES)
    reg [ADDR_WIDTH:0]   rd_idx;     // read beats issued
    reg [ADDR_WIDTH:0]   wr_idx;     // write beats retired
    reg [LANE_BITS-1:0]  last_lanes; // valid lanes in the final tile

    reg                  r1_valid;   // read-data-valid, aligned to mem latency
    reg [LANE_BITS-1:0]  r1_lanes;

    // ---- combinational descriptor decode of an incoming START ----
    wire [ADDR_WIDTH:0] nbeats_c =
        (len == {LEN_WIDTH{1'b0}}) ? {(ADDR_WIDTH+1){1'b0}}
                                   : ((len + LANES - 1) / LANES);
    wire [ADDR_WIDTH:0]  full_beats = (nbeats_c == 0) ? 0 : (nbeats_c - 1);
    wire [LEN_WIDTH-1:0] rem_c      = len - full_beats * LANES; // 1..LANES

    // ---- read stage (combinational address generation) ----
    wire issuing = (state == S_RUN) && (rd_idx < nbeats);
    wire is_last = (rd_idx == nbeats - 1);
    wire [LANE_BITS-1:0] lanes_this =
        is_last ? last_lanes : LANES[LANE_BITS-1:0];

    assign mem_rd_en   = issuing;
    assign mem_rd_addr = src_q + rd_idx * LANES;

    // ---- scan datapath inputs (aligned to returned read data) ----
    assign dp_mode_excl = mode_q;
    assign dp_in_valid  = r1_valid;
    assign dp_in_data   = mem_rd_data;
    assign dp_in_lanes  = r1_lanes;

    // ---- write stage (combinational, aligned to scanned beat) ----
    assign mem_wr_en    = dp_out_valid;
    assign mem_wr_addr  = dst_q + wr_idx * LANES;
    assign mem_wr_lanes = dp_out_lanes;
    assign mem_wr_data  = dp_out_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            cycles     <= 32'd0;
            src_q      <= {ADDR_WIDTH{1'b0}};
            dst_q      <= {ADDR_WIDTH{1'b0}};
            len_q      <= {LEN_WIDTH{1'b0}};
            mode_q     <= 1'b0;
            nbeats     <= {(ADDR_WIDTH+1){1'b0}};
            rd_idx     <= {(ADDR_WIDTH+1){1'b0}};
            wr_idx     <= {(ADDR_WIDTH+1){1'b0}};
            last_lanes <= {LANE_BITS{1'b0}};
            r1_valid   <= 1'b0;
            r1_lanes   <= {LANE_BITS{1'b0}};
            clr_carry  <= 1'b0;
        end else begin
            clr_carry <= 1'b0;  // single-cycle strobe

            case (state)
            // -------------------------------------------------------------
            S_IDLE: begin
                busy     <= 1'b0;
                r1_valid <= 1'b0;
                if (start) begin
                    src_q      <= src_addr;
                    dst_q      <= dst_addr;
                    len_q      <= len;
                    mode_q     <= mode_excl;
                    nbeats     <= nbeats_c;
                    last_lanes <= rem_c[LANE_BITS-1:0];
                    rd_idx     <= {(ADDR_WIDTH+1){1'b0}};
                    wr_idx     <= {(ADDR_WIDTH+1){1'b0}};
                    cycles     <= 32'd0;
                    done       <= 1'b0;
                    clr_carry  <= 1'b1;             // zero the running carry
                    if (nbeats_c == 0) begin
                        done  <= 1'b1;              // empty descriptor
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end else begin
                        busy  <= 1'b1;
                        state <= S_RUN;
                    end
                end
            end
            // -------------------------------------------------------------
            S_RUN: begin
                cycles <= cycles + 32'd1;

                // read issue -> advance r1 pipeline
                if (issuing) begin
                    rd_idx   <= rd_idx + 1'b1;
                    r1_valid <= 1'b1;
                    r1_lanes <= lanes_this;
                end else begin
                    r1_valid <= 1'b0;
                end

                // write retire
                if (dp_out_valid) begin
                    wr_idx <= wr_idx + 1'b1;
                    if (wr_idx == nbeats - 1)
                        state <= S_DONE;           // final beat has landed
                end
            end
            // -------------------------------------------------------------
            S_DONE: begin
                cycles <= cycles + 32'd1;          // count the retire cycle
                busy   <= 1'b0;
                done   <= 1'b1;
                state  <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
