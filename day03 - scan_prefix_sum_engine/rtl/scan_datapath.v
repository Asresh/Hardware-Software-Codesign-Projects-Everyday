// -----------------------------------------------------------------------------
// scan_datapath.v
// One pipeline stage that turns a raw memory beat (LANES words) into the
// corresponding slice of the running device-wide scan, then registers it.
//
//   masked  : lanes >= valid_lanes are forced to 0 so a short final tile does
//             not corrupt the tree or the carry.
//   tree    : prefix_tree gives the in-tile inclusive scan + tile total.
//   mode    : exclusive[i] = inclusive[i] - masked[i]; a mux picks inclusive
//             or exclusive.
//   carry   : out[i] = selected[i] + carry_reg, where carry_reg holds the sum
//             of every element in all earlier tiles. carry_reg advances by the
//             tile total each accepted beat. clr_carry (pulsed at job start)
//             zeroes it.
//
// in_valid -> (1 cycle) -> out_valid. Everything is registered on in_valid so
// the controller can stream one beat per clock.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module scan_datapath #(
    parameter integer LANES     = 16,
    parameter integer W         = 32,
    parameter integer LANE_BITS = 5     // ceil(log2(LANES))+1, holds 0..LANES
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  clr_carry,   // pulse at job start: carry <- 0
    input  wire                  mode_excl,   // 1 = exclusive scan, 0 = inclusive

    input  wire                  in_valid,    // a read beat is presented this cycle
    input  wire [LANES*W-1:0]    in_data,     // raw beat from memory
    input  wire [LANE_BITS-1:0]  in_lanes,    // number of valid lanes (1..LANES)

    output reg                   out_valid,   // scanned beat valid (1 cycle later)
    output reg  [LANES*W-1:0]    out_data,    // scanned beat, carry applied
    output reg  [LANE_BITS-1:0]  out_lanes    // valid-lane count passed through
);
    // ---- mask short final tile to zero on the dead lanes ----
    wire [LANES*W-1:0] masked;
    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_mask
            assign masked[g*W +: W] =
                (g < in_lanes) ? in_data[g*W +: W] : {W{1'b0}};
        end
    endgenerate

    // ---- in-tile parallel-prefix scan ----
    wire [LANES*W-1:0] inclusive;
    wire [W-1:0]       tile_total;
    prefix_tree #(.LANES(LANES), .W(W)) u_tree (
        .din(masked), .inclusive(inclusive), .total(tile_total)
    );

    // ---- mode select + running carry add ----
    reg [W-1:0] carry_reg;
    wire [LANES*W-1:0] out_comb;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_sel
            wire [W-1:0] inc_i = inclusive[g*W +: W];
            wire [W-1:0] exc_i = inc_i - masked[g*W +: W];  // exclusive within tile
            wire [W-1:0] sel_i = mode_excl ? exc_i : inc_i;
            assign out_comb[g*W +: W] = sel_i + carry_reg;
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            carry_reg <= {W{1'b0}};
            out_valid <= 1'b0;
            out_data  <= {LANES*W{1'b0}};
            out_lanes <= {LANE_BITS{1'b0}};
        end else begin
            if (clr_carry)
                carry_reg <= {W{1'b0}};

            out_valid <= in_valid;
            if (in_valid) begin
                out_data  <= out_comb;
                out_lanes <= in_lanes;
                // advance carry by this tile's total (uses pre-update carry above)
                carry_reg <= carry_reg + tile_total;
            end
        end
    end
endmodule

`default_nettype wire
