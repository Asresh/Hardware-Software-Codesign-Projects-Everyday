// ============================================================================
// kds_devq - the device slot array: one execution context per GPU / stream
//            queue, each a countdown timer over the node it is running.
//
// A slot is loaded on dispatch with duration-1 and counts down one tick per
// clock. When a busy slot is sitting at zero it retires its node at the end of
// that tick: the retirement is registered, so the freed slot and the done bit
// both appear on the next tick and a dependent can be issued immediately.
// A node therefore holds its device for duration+1 ticks - one issue cycle
// plus `duration` execution ticks - and finish = start + duration + 1.
//
// Retirements are a per-device vector, not a single event: two slots hitting
// zero on the same tick both retire on that tick.
//
// A dispatch target is by construction an idle slot (kds_placer only selects
// from free_mask), so the load and the retire path never collide.
// ============================================================================
`include "kds_defs.vh"

module kds_devq #(
    parameter DEVICES = `KDS_DEVICES,
    parameter NIDW    = 6,
    parameter DIDW    = 2
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    clear,        // start of a graph launch
    input  wire                    tick_en,      // RUN phase advance

    input  wire                    disp_valid,
    input  wire [DIDW-1:0]         disp_dev,
    input  wire [NIDW-1:0]         disp_node,
    input  wire [15:0]             disp_dur,

    output wire [DEVICES-1:0]      busy,
    output wire [DEVICES-1:0]      comp_valid,   // retiring on this tick
    output wire [DEVICES*NIDW-1:0] comp_node_flat
);

    reg [DEVICES-1:0]  busy_q;
    reg [15:0]         rem_q  [0:DEVICES-1];
    reg [NIDW-1:0]     node_q [0:DEVICES-1];

    integer u;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= {DEVICES{1'b0}};
            for (u = 0; u < DEVICES; u = u + 1) begin
                rem_q[u]  <= 16'd0;
                node_q[u] <= {NIDW{1'b0}};
            end
        end else if (clear) begin
            busy_q <= {DEVICES{1'b0}};
        end else if (tick_en) begin
            for (u = 0; u < DEVICES; u = u + 1) begin
                if (busy_q[u]) begin
                    if (rem_q[u] == 16'd0) busy_q[u] <= 1'b0;      // retire
                    else                   rem_q[u]  <= rem_q[u] - 16'd1;
                end
            end
            if (disp_valid) begin
                busy_q[disp_dev] <= 1'b1;
                rem_q [disp_dev] <= disp_dur - 16'd1;
                node_q[disp_dev] <= disp_node;
            end
        end
    end

    genvar gu;
    generate
        for (gu = 0; gu < DEVICES; gu = gu + 1) begin : g_dev
            assign comp_valid[gu]                  = busy_q[gu] & (rem_q[gu] == 16'd0);
            assign comp_node_flat[gu*NIDW +: NIDW] = node_q[gu];
        end
    endgenerate

    assign busy = busy_q;

endmodule
