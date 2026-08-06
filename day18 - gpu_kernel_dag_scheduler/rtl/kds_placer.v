// ============================================================================
// kds_placer - placement and arbitration.
//
// A node is *placeable* when it is ready AND at least one of the devices its
// affinity mask allows is idle:
//
//      placeable[i] = ready[i] & |(dev[i] & free)
//
// Of the placeable nodes the lowest index wins, and it goes to the lowest
// allowed idle device. Both tie-breaks are fixed, so the schedule is a pure
// function of the graph - never of bus timing, never of arbitration history -
// which is what lets the golden model predict it tick for tick.
//
// The node select is a two-level (group-of-8) priority encoder rather than a
// 64-long ripple chain, so the depth grows as log of the scoreboard, not
// linearly: eight 8-bit OR reductions pick the group, one 8-bit encode picks
// the bit inside it.
// ============================================================================
`include "kds_defs.vh"

module kds_placer #(
    parameter MAX_NODES = `KDS_MAX_NODES,
    parameter DEVICES   = `KDS_DEVICES,
    parameter NIDW      = 6,
    parameter DIDW      = 2
) (
    input  wire [MAX_NODES-1:0]         ready,
    input  wire [MAX_NODES*DEVICES-1:0] dev_flat,
    input  wire [DEVICES-1:0]           free_mask,

    output reg                          sel_valid,
    output reg  [NIDW-1:0]              sel_node,
    output reg  [DIDW-1:0]              sel_dev,
    output reg  [DEVICES-1:0]           sel_dev_oh
);

    localparam GW   = 8;                                  // encoder group width
    localparam NG   = (MAX_NODES + GW - 1) / GW;
    localparam PADW = NG * GW;

    reg [PADW-1:0] pl_pad;                                // placeable, padded
    reg [NG-1:0]   gany;                                  // group has a hit
    reg [DEVICES-1:0] devsel;

    integer i, g, gi, bi, di;
    integer gidx, nidx;

    always @* begin
        // ---- placeable ----------------------------------------------------
        pl_pad = {PADW{1'b0}};
        for (i = 0; i < MAX_NODES; i = i + 1)
            pl_pad[i] = ready[i] & (|(dev_flat[i*DEVICES +: DEVICES] & free_mask));

        // ---- level 1: which group of eight holds the winner ---------------
        for (g = 0; g < NG; g = g + 1)
            gany[g] = |pl_pad[g*GW +: GW];

        sel_valid = 1'b0;
        gidx      = 0;
        for (gi = NG - 1; gi >= 0; gi = gi - 1)
            if (gany[gi]) begin gidx = gi; sel_valid = 1'b1; end

        // ---- level 2: which bit inside that group -------------------------
        nidx = gidx * GW;
        for (bi = GW - 1; bi >= 0; bi = bi - 1)
            if (pl_pad[gidx*GW + bi]) nidx = gidx * GW + bi;

        sel_node = nidx[NIDW-1:0];

        // ---- device: lowest allowed idle slot ------------------------------
        devsel     = dev_flat[nidx*DEVICES +: DEVICES] & free_mask;
        sel_dev    = {DIDW{1'b0}};
        sel_dev_oh = {DEVICES{1'b0}};
        for (di = DEVICES - 1; di >= 0; di = di - 1)
            if (devsel[di]) sel_dev = di[DIDW-1:0];
        if (sel_valid) sel_dev_oh[sel_dev] = 1'b1;
    end

endmodule
