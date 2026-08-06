// ============================================================================
// kds_node_mem - the on-chip graph store.
//
// One entry per scoreboard slot: execution duration, device-affinity mask,
// the full predecessor bitmask and the opaque kernel id. The dependency masks
// and the affinity masks leave the module *in parallel* (dep_flat / dev_flat)
// because the scoreboard compares every entry against the retirement mask on
// every tick - that wide read port is what makes this an associative store
// rather than a RAM. Duration and kernel id are read one at a time (dispatch
// and writeback only ever touch one node per cycle) so they stay behind a
// narrow mux.
//
// A whole node record is written in one go, when its last memory word lands.
// ============================================================================
`include "kds_defs.vh"

module kds_node_mem #(
    parameter MAX_NODES = `KDS_MAX_NODES,
    parameter DEVICES   = `KDS_DEVICES,
    parameter NIDW      = 6
) (
    input  wire                            clk,

    // write port - one complete node record
    input  wire                            we,
    input  wire [NIDW-1:0]                 waddr,
    input  wire [15:0]                     wdur,
    input  wire [DEVICES-1:0]              wdev,
    input  wire [MAX_NODES-1:0]            wdep,
    input  wire [31:0]                     wkid,

    // parallel read of every dependency / affinity mask
    output wire [MAX_NODES*MAX_NODES-1:0]  dep_flat,
    output wire [MAX_NODES*DEVICES-1:0]    dev_flat,

    // narrow read port (dispatch reads the duration, writeback the kernel id)
    input  wire [NIDW-1:0]                 raddr,
    output wire [15:0]                     rdur,
    output wire [31:0]                     rkid
);

    reg [MAX_NODES-1:0] dep_q [0:MAX_NODES-1];
    reg [DEVICES-1:0]   dev_q [0:MAX_NODES-1];
    reg [15:0]          dur_q [0:MAX_NODES-1];
    reg [31:0]          kid_q [0:MAX_NODES-1];

    always @(posedge clk) begin
        if (we) begin
            dep_q[waddr] <= wdep;
            dev_q[waddr] <= wdev;
            dur_q[waddr] <= wdur;
            kid_q[waddr] <= wkid;
        end
    end

    genvar i;
    generate
        for (i = 0; i < MAX_NODES; i = i + 1) begin : g_flat
            assign dep_flat[i*MAX_NODES +: MAX_NODES] = dep_q[i];
            assign dev_flat[i*DEVICES   +: DEVICES]   = dev_q[i];
        end
    endgenerate

    assign rdur = dur_q[raddr];
    assign rkid = kid_q[raddr];

endmodule
