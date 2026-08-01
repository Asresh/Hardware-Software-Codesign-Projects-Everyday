// ============================================================================
// seq_tracker - per-channel sequence-gap detection for market-data feeds
//
//   A feed handler must notice a *dropped* packet (a hole in the per-channel
//   sequence numbers) as fast as it notices a corrupt one - a silent gap means
//   the strategy is trading on a stale book. This keeps the last accepted
//   sequence number per channel in a small distributed RAM and, in the same
//   cycle the parser reports a completed packet, checks seq == last + 1.
//
//   The read is combinational (aligned to the parser's result strobe), the
//   update is registered. `check_en` gates gap detection; `soft_rst` clears the
//   valid bits so a channel's first packet after reset is never a false gap.
//   Malformed packets (frame_err) neither check nor update the tracker.
// ============================================================================
`default_nettype none

module seq_tracker #(
    parameter integer CHW = 8            // channel index bits (NCH = 2**CHW)
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        soft_rst,
    input  wire        check_en,

    input  wire        pv,               // packet-complete strobe from parser
    input  wire [15:0] channel,
    input  wire [31:0] seq,
    input  wire        frame_err,

    output wire        seq_ok,           // 1 = in order (or first / disabled)
    output wire        seq_first,        // 1 = first packet seen on channel
    output wire [31:0] expected_seq
);
    localparam integer NCH = (1 << CHW);

    reg [31:0] last_seq [0:NCH-1];
    reg        valid    [0:NCH-1];

    wire [CHW-1:0] idx  = channel[CHW-1:0];
    wire           have = valid[idx];
    wire [31:0]    last = last_seq[idx];

    assign seq_first    = pv & ~have;
    assign expected_seq = have ? (last + 32'd1) : seq;

    wire gap = pv & check_en & have & ~frame_err & (seq != last + 32'd1);
    assign seq_ok = ~gap;

    integer i;
    always @(posedge clk) begin
        if (!rst_n || soft_rst) begin
            for (i = 0; i < NCH; i = i + 1)
                valid[i] <= 1'b0;
        end else if (pv & ~frame_err) begin
            last_seq[idx] <= seq;
            valid[idx]    <= 1'b1;
        end
    end
endmodule

`default_nettype wire
