// ============================================================================
// pkt_parser - AXI4-Stream market-data packet framing + CRC accumulation
//
//   Consumes one 32-bit beat per clock and frames a feed packet:
//
//     beat 0   : { channel_id[15:0], plen_bytes[15:0] }   (header word 0)
//     beat 1   : { seq_no[31:0] }                          (header word 1)
//     beats .. : payload words (ceil(plen/4) of them; last may be partial)
//     beat N   : { expected_crc[31:0] }  with TLAST=1      (trailer / FCS)
//
//   The CRC-32 covers the two header words and exactly `plen` payload bytes
//   (the trailer itself is not CRC'd - it *is* the CRC). The running state is
//   folded a whole word per clock through crc32_unit, with a 1..4 byte select
//   on the final partial payload word. On the trailer beat the state is
//   finalised (xor 0xFFFFFFFF) and compared against the wire value.
//
//   Framing is validated two ways: byte accounting from `plen` says which beat
//   is the trailer, and TLAST must agree. A TLAST that lands early, or a
//   trailer beat without TLAST, raises `frame_err` and the FSM resynchronises
//   at the next start-of-packet so a malformed packet cannot corrupt the next.
// ============================================================================
`default_nettype none

module pkt_parser #(
    parameter [31:0] CRC_INIT = 32'hFFFFFFFF,
    parameter [31:0] CRC_XOR  = 32'hFFFFFFFF
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,           // engine enable (gates TREADY)

    // AXI4-Stream packet ingress
    input  wire [31:0] s_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,
    input  wire        s_tlast,

    // Per-packet result (one-cycle strobe)
    output reg         res_valid,
    output reg  [15:0] res_channel,
    output reg  [31:0] res_seq,
    output reg  [31:0] res_crc,      // computed, finalised
    output reg  [31:0] res_exp_crc,  // trailer value on the wire
    output reg  [15:0] res_plen,
    output reg         res_crc_ok,
    output reg         res_frame_err
);
    // ---- states ----
    localparam [2:0] S_HDR0    = 3'd0,
                     S_HDR1    = 3'd1,
                     S_PAYLOAD = 3'd2,
                     S_TRAILER = 3'd3,
                     S_FLUSH   = 3'd4;   // eat beats of a malformed packet to TLAST

    reg  [2:0]  state;
    reg  [31:0] crc;          // running state (pre-finalise)
    reg  [15:0] channel;
    reg  [31:0] seq;
    reg  [15:0] plen;         // payload bytes declared in header
    reg  [15:0] rem;          // payload bytes still to CRC

    // ready whenever enabled; the datapath is single-cycle so never stalls
    assign s_tready = en;
    wire beat = s_tvalid & s_tready;

    // bytes to fold from this payload beat: 4, or the partial tail
    wire [2:0]  pbytes = (rem >= 16'd4) ? 3'd4 : rem[2:0];

    // combinational CRC folds (header words are always full 4-byte folds)
    wire [31:0] crc_hdr;
    wire [31:0] crc_pay;
    crc32_unit u_crc_hdr (.crc_in(crc),      .data(s_tdata), .nbytes(3'd4),   .crc_out(crc_hdr));
    crc32_unit u_crc_pay (.crc_in(crc),      .data(s_tdata), .nbytes(pbytes), .crc_out(crc_pay));

    // is this payload beat the last one? (rem drops to zero after it)
    wire payload_last = (rem <= 16'd4);

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_HDR0;
            crc       <= CRC_INIT;
            res_valid <= 1'b0;
        end else begin
            res_valid <= 1'b0;   // default: strobe low

            if (beat) begin
                case (state)
                // ---- header word 0: channel + payload length ----
                S_HDR0: begin
                    channel <= s_tdata[31:16];
                    plen    <= s_tdata[15:0];
                    rem     <= s_tdata[15:0];
                    crc     <= crc_hdr;                 // fold 4 header bytes
                    if (s_tlast) begin                  // impossibly short -> malformed
                        res_valid     <= 1'b1;
                        res_frame_err <= 1'b1;
                        res_crc_ok    <= 1'b0;
                        res_channel   <= s_tdata[31:16];
                        res_seq       <= 32'd0;
                        res_crc       <= 32'd0;
                        res_exp_crc   <= 32'd0;
                        res_plen      <= s_tdata[15:0];
                        state         <= S_HDR0;
                        crc           <= CRC_INIT;
                    end else begin
                        state <= S_HDR1;
                    end
                end
                // ---- header word 1: sequence number ----
                S_HDR1: begin
                    seq <= s_tdata;
                    crc <= crc_hdr;                     // fold 4 header bytes
                    if (s_tlast) begin
                        // trailer where a seq word was expected -> malformed
                        res_valid     <= 1'b1;
                        res_frame_err <= 1'b1;
                        res_crc_ok    <= 1'b0;
                        res_channel   <= channel;
                        res_seq       <= s_tdata;
                        res_crc       <= 32'd0;
                        res_exp_crc   <= 32'd0;
                        res_plen      <= plen;
                        state         <= S_HDR0;
                        crc           <= CRC_INIT;
                    end else begin
                        state <= (plen == 16'd0) ? S_TRAILER : S_PAYLOAD;
                    end
                end
                // ---- payload words ----
                S_PAYLOAD: begin
                    crc <= crc_pay;
                    rem <= rem - {13'b0, pbytes};
                    if (s_tlast) begin
                        // TLAST inside payload -> short packet, malformed
                        res_valid     <= 1'b1;
                        res_frame_err <= 1'b1;
                        res_crc_ok    <= 1'b0;
                        res_channel   <= channel;
                        res_seq       <= seq;
                        res_crc       <= 32'd0;
                        res_exp_crc   <= 32'd0;
                        res_plen      <= plen;
                        state         <= S_HDR0;
                        crc           <= CRC_INIT;
                    end else if (payload_last) begin
                        state <= S_TRAILER;
                    end
                end
                // ---- trailer: expected CRC on the wire, must carry TLAST ----
                S_TRAILER: begin
                    res_valid     <= 1'b1;
                    res_channel   <= channel;
                    res_seq       <= seq;
                    res_crc       <= crc ^ CRC_XOR;     // finalise
                    res_exp_crc   <= s_tdata;
                    res_plen      <= plen;
                    res_crc_ok    <= s_tlast & ((crc ^ CRC_XOR) == s_tdata);
                    res_frame_err <= ~s_tlast;          // trailer without TLAST
                    crc           <= CRC_INIT;
                    // if TLAST missing, the real trailer is still coming: flush it
                    state         <= s_tlast ? S_HDR0 : S_FLUSH;
                end
                // ---- swallow the rest of a malformed packet up to TLAST ----
                S_FLUSH: begin
                    if (s_tlast) begin
                        state <= S_HDR0;
                        crc   <= CRC_INIT;
                    end
                end
                default: state <= S_HDR0;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
