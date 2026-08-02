// ============================================================================
// moe_capacity.v - per-expert capacity counters + routing statistics.
//
// Real MoE layers cap how many tokens each expert may accept per batch so the
// expert shards stay load-balanced; tokens over the cap are dropped from that
// slot.  This block holds a per-expert accepted-token counter, tests each
// selected expert against the programmable capacity, and updates the counters
// and running statistics in a single cycle.  Because the check and the update
// live in the same stage and one token retires per clock, back-to-back tokens
// routed to the same expert observe correctly incremented counts with no
// hazard (a natural read-modify-write).  The two selected experts are always
// distinct, so both counters can update in the same cycle.
// ============================================================================
`default_nettype none

module moe_capacity #(
    parameter integer E  = 8,
    parameter integer IW = 8
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire            clr,        // soft-reset: clear counters + stats
    input  wire [31:0]     cap,
    input  wire            fire,       // a token is retiring this cycle
    input  wire [IW-1:0]   e0,
    input  wire [IW-1:0]   e1,
    output wire            ov0,        // top-0 slot over capacity (dropped)
    output wire            ov1,        // top-1 slot over capacity (dropped)
    output wire [1:0]      routed,     // accepted slots this token
    output wire            ovf_pulse,  // any drop this cycle (IRQ source)
    output wire [E*32-1:0] load_flat,  // per-expert counters (to CSR)
    output reg  [31:0]     tokens,
    output reg  [31:0]     routed_tot,
    output reg  [31:0]     overflow_tot
);
    reg [31:0] load [0:E-1];
    integer i;

    assign ov0    = (load[e0] >= cap);
    assign ov1    = (load[e1] >= cap);
    assign routed = (~ov0) + (~ov1);
    assign ovf_pulse = fire & (ov0 | ov1);

    genvar g;
    generate
        for (g = 0; g < E; g = g + 1) begin : G_LOAD
            assign load_flat[g*32 +: 32] = load[g];
        end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n || clr) begin
            for (i = 0; i < E; i = i + 1) load[i] <= 32'd0;
            tokens       <= 32'd0;
            routed_tot   <= 32'd0;
            overflow_tot <= 32'd0;
        end else if (fire) begin
            for (i = 0; i < E; i = i + 1) begin
                if ((i[IW-1:0] == e0 && !ov0) || (i[IW-1:0] == e1 && !ov1))
                    load[i] <= load[i] + 32'd1;
            end
            tokens       <= tokens + 32'd1;
            routed_tot   <= routed_tot + {30'd0, routed};
            overflow_tot <= overflow_tot + {30'd0, ({1'b0,ov0} + {1'b0,ov1})};
        end
    end
endmodule

`default_nettype wire
