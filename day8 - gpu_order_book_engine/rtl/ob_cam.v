// ============================================================================
// ob_cam - content-addressable price-level map (the associative memory).
//
// Holds N price levels, each { valid, side, price, qty }. Every incoming
// message associatively matches (side, price) against ALL levels in parallel
// in a single cycle:
//   * hit  -> apply the op to that level's quantity (ADD/SUB/SET/CLR), and
//             free the level (valid <- 0) when the quantity reaches zero;
//   * miss -> ADD/SET with non-zero qty allocates the first free level; a full
//             book raises a sticky overflow flag and drops the message; SUB/CLR
//             on a miss is a no-op.
// The whole match + allocate + update is combinational from the registered
// level array to the next array, so the engine sustains one message per clock.
// ============================================================================
`default_nettype none
module ob_cam #(
    parameter integer PW = 16,
    parameter integer QW = 24,
    parameter integer N  = 32
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              soft_reset,   // clear the whole book
    input  wire              ovf_clr,      // clear sticky overflow
    input  wire              upd,          // a message is being applied
    input  wire [1:0]        in_op,
    input  wire              in_side,
    input  wire [PW-1:0]     in_price,
    input  wire [QW-1:0]     in_qty,
    output wire [N-1:0]      o_valid,
    output wire [N-1:0]      o_side,
    output wire [N*PW-1:0]   o_price,
    output wire [N*QW-1:0]   o_qty,
    output reg               overflow,
    output wire [$clog2(N+1)-1:0] active_count
);
    localparam integer CW = $clog2(N + 1);

    reg [N-1:0]  valid, side;
    reg [PW-1:0] price [0:N-1];
    reg [QW-1:0] qty   [0:N-1];

    integer i;

    // ---- parallel associative match + free-slot detection (combinational) ----
    reg [N-1:0] match, freev;
    always @* begin
        for (i = 0; i < N; i = i + 1) begin
            match[i] = valid[i] & (side[i] == in_side) & (price[i] == in_price);
            freev[i] = ~valid[i];
        end
    end
    wire hit_any  = |match;
    wire has_free = |freev;

    // lowest matching / free index (priority encoder, low index wins)
    reg [CW-1:0] hit_idx, free_idx;
    always @* begin
        hit_idx = {CW{1'b0}};
        free_idx = {CW{1'b0}};
        for (i = N-1; i >= 0; i = i - 1) begin
            if (match[i]) hit_idx  = i[CW-1:0];
            if (freev[i]) free_idx = i[CW-1:0];
        end
    end

    // ---- next quantity for a hit ----
    reg [QW-1:0] newq;
    always @* begin
        case (in_op)
            2'd0: newq = qty[hit_idx] + in_qty;                                  // ADD (wraps mod 2^QW)
            2'd1: newq = (qty[hit_idx] > in_qty) ? (qty[hit_idx] - in_qty)
                                                 : {QW{1'b0}};                    // SUB (clamp)
            2'd2: newq = in_qty;                                                  // SET
            default: newq = {QW{1'b0}};                                           // CLR
        endcase
    end

    wire is_alloc_op = (in_op == 2'd0) || (in_op == 2'd2);         // ADD or SET
    wire alloc_req   = upd & ~hit_any & is_alloc_op & (in_qty != {QW{1'b0}});
    wire set_ovf     = alloc_req & ~has_free;

    // ---- state update ----
    always @(posedge clk) begin
        if (!rst_n || soft_reset) begin
            valid    <= {N{1'b0}};
            overflow <= 1'b0;
        end else begin
            if (upd && hit_any) begin
                qty[hit_idx] <= newq;
                if (newq == {QW{1'b0}})
                    valid[hit_idx] <= 1'b0;                 // free at zero qty
            end else if (alloc_req && has_free) begin
                valid[free_idx] <= 1'b1;
                side[free_idx]  <= in_side;
                price[free_idx] <= in_price;
                qty[free_idx]   <= in_qty;                  // ADD-from-0 == SET == in_qty
            end

            // sticky overflow: set on a full-book miss, cleared by ack
            if (ovf_clr)      overflow <= 1'b0;
            else if (set_ovf) overflow <= 1'b1;
        end
    end

    // ---- active-level population count ----
    reg [CW-1:0] acnt;
    always @* begin
        acnt = {CW{1'b0}};
        for (i = 0; i < N; i = i + 1)
            acnt = acnt + {{(CW-1){1'b0}}, valid[i]};
    end
    assign active_count = acnt;

    // ---- flatten the level array to the reduction trees ----
    assign o_valid = valid;
    assign o_side  = side;
    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : flatten
            assign o_price[g*PW +: PW] = price[g];
            assign o_qty  [g*QW +: QW] = qty[g];
        end
    endgenerate
endmodule
`default_nettype wire
