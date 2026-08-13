// -----------------------------------------------------------------------------
// sort_ctrl.v
// Descriptor-driven controller + coalesced wide-DMA address generator for the
// tiled bitonic sort engine.
//
// A descriptor is {SRC base, DST base, NTILES, MODE}. On START the engine walks
// source memory in coalesced beats of N keys (an N*W-bit GPU-style wide access =
// exactly one tile), streams each beat through the pipelined bitonic network,
// and writes the sorted beat back to destination memory - a single pass, one
// tile in and one sorted tile out per clock, with no host round-trips.
//
// The read side issues one beat address per clock. Device memory returns data
// one cycle later, so a 1-cycle valid register (r1_valid) aligns the tile with
// the returned data before it enters the network. The network has a fixed
// latency; beats retire strictly in order, so a single write index reconstructs
// each sorted tile's destination address. DONE is raised when the last tile has
// been written back. A free-running counter measures the exact START->DONE
// latency exposed through the CSR CYCLES register.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module sort_ctrl #(
    parameter integer N          = 16,   // keys per tile / words per beat
    parameter integer W          = 32,   // key width
    parameter integer ADDR_WIDTH = 20,   // word address space
    parameter integer TILE_WIDTH = 16    // max tile-count width
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- descriptor + control (from CSR block) ----
    input  wire                   start,        // 1-cycle pulse
    input  wire [ADDR_WIDTH-1:0]  src_addr,     // source base (word address)
    input  wire [ADDR_WIDTH-1:0]  dst_addr,     // destination base (word address)
    input  wire [TILE_WIDTH-1:0]  ntiles,       // number of N-key tiles to sort
    input  wire                   mode_desc,    // 1 = descending, 0 = ascending

    output reg                    busy,
    output reg                    done,         // sticky until next start
    output reg  [31:0]            cycles,       // START->DONE latency of last job

    // ---- wide (coalesced) memory master ----
    output wire                   mem_rd_en,
    output wire [ADDR_WIDTH-1:0]  mem_rd_addr,
    input  wire [N*W-1:0]         mem_rd_data,   // valid 1 cycle after mem_rd_en

    output wire                   mem_wr_en,
    output wire [ADDR_WIDTH-1:0]  mem_wr_addr,
    output wire [N*W-1:0]         mem_wr_data,

    // ---- bitonic network handshake ----
    output wire                   dp_in_valid,
    output wire                   dp_in_desc,
    output wire [N*W-1:0]         dp_in_data,
    input  wire                   dp_out_valid,
    input  wire [N*W-1:0]         dp_out_data
);
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;
    reg [1:0] state;

    reg [ADDR_WIDTH-1:0] src_q, dst_q;
    reg [TILE_WIDTH:0]   ntiles_q;      // one extra bit for clean compares
    reg                  mode_q;
    reg [TILE_WIDTH:0]   rd_idx;        // read beats issued
    reg [TILE_WIDTH:0]   wr_idx;        // sorted beats retired

    reg                  r1_valid;      // read-data-valid, aligned to mem latency

    // ---- read stage (combinational address generation) ----
    wire issuing = (state == S_RUN) && (rd_idx < ntiles_q);
    assign mem_rd_en   = issuing;
    assign mem_rd_addr = src_q + rd_idx * N;

    // ---- network inputs (aligned to the returned read data) ----
    assign dp_in_valid = r1_valid;
    assign dp_in_desc  = mode_q;
    assign dp_in_data  = mem_rd_data;

    // ---- write stage (combinational, aligned to the sorted beat) ----
    assign mem_wr_en   = dp_out_valid;
    assign mem_wr_addr = dst_q + wr_idx * N;
    assign mem_wr_data = dp_out_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            cycles   <= 32'd0;
            src_q    <= {ADDR_WIDTH{1'b0}};
            dst_q    <= {ADDR_WIDTH{1'b0}};
            ntiles_q <= {(TILE_WIDTH+1){1'b0}};
            mode_q   <= 1'b0;
            rd_idx   <= {(TILE_WIDTH+1){1'b0}};
            wr_idx   <= {(TILE_WIDTH+1){1'b0}};
            r1_valid <= 1'b0;
        end else begin
            case (state)
            // -------------------------------------------------------------
            S_IDLE: begin
                busy     <= 1'b0;
                r1_valid <= 1'b0;
                if (start) begin
                    src_q    <= src_addr;
                    dst_q    <= dst_addr;
                    ntiles_q <= {1'b0, ntiles};
                    mode_q   <= mode_desc;
                    rd_idx   <= {(TILE_WIDTH+1){1'b0}};
                    wr_idx   <= {(TILE_WIDTH+1){1'b0}};
                    cycles   <= 32'd0;
                    done     <= 1'b0;
                    if (ntiles == {TILE_WIDTH{1'b0}}) begin
                        done  <= 1'b1;              // empty descriptor: nothing to do
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

                // read issue -> advance the read-data-valid alignment register
                if (issuing) begin
                    rd_idx   <= rd_idx + 1'b1;
                    r1_valid <= 1'b1;
                end else begin
                    r1_valid <= 1'b0;
                end

                // sorted-tile retire
                if (dp_out_valid) begin
                    wr_idx <= wr_idx + 1'b1;
                    if (wr_idx == ntiles_q - 1)
                        state <= S_DONE;            // last sorted tile has landed
                end
            end
            // -------------------------------------------------------------
            S_DONE: begin
                cycles <= cycles + 32'd1;           // count the retire cycle
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
