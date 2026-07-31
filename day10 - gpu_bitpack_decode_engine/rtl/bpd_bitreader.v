// ============================================================================
// bpd_bitreader.v  -  variable-rate bitstream reader / aligner
//
// A wide bit FIFO sitting on the 32-bit AXI4-Stream compressed ingress. It
// accumulates incoming words LSB-first into a BUFW-bit buffer and exposes the
// low WINW bits as a combinational "window" for the field extractor. The
// consumer drops an arbitrary number of bits per clock via {pop_en, pop_bits}
// (used both for the 32-bit block headers and for groups of packed fields).
//
// The reader is autonomously greedy: it asserts tready and swallows a word
// whenever there will be room after this cycle's pop, so the window is kept as
// full as the ingress bandwidth allows. Pop and push happen in the same cycle.
// ============================================================================
`default_nettype none

module bpd_bitreader #(
    parameter integer IN_W  = 32,   // ingress word width
    parameter integer BUFW  = 192,  // internal bit buffer width
    parameter integer WINW  = 128   // exposed combinational window width
) (
    input  wire                 clk,
    input  wire                 rst,      // sync, active high
    input  wire                 flush,    // drop all buffered bits

    // AXI4-Stream slave (compressed words in)
    input  wire [IN_W-1:0]      s_tdata,
    input  wire                 s_tvalid,
    output wire                 s_tready,
    input  wire                 s_tlast,  // frame delimiter (informational)

    // bit-consume interface
    input  wire                 pop_en,
    input  wire [8:0]           pop_bits, // 0..WINW bits to drop this cycle

    // combinational window + status
    output wire [WINW-1:0]      window,
    output wire [8:0]           valid_bits,
    output wire                 last_seen // tlast of a swallowed word was seen
);
    localparam integer CNTW = 9; // enough for BUFW<=511

    reg [BUFW-1:0] buf_q;
    reg [CNTW-1:0] cnt_q;
    reg            last_q;

    wire [CNTW-1:0] pop_amt = pop_en ? pop_bits : {CNTW{1'b0}};
    // bit count remaining after this cycle's pop
    wire [CNTW-1:0] cnt_after_pop = cnt_q - pop_amt;
    // room to accept one more IN_W-bit word after the pop
    wire            has_room = (cnt_after_pop <= (BUFW - IN_W));
    wire            accept   = s_tvalid & has_room;

    assign s_tready   = has_room;
    assign window     = buf_q[WINW-1:0];
    assign valid_bits = cnt_q;
    assign last_seen  = last_q;

    // shifted-in word lands at bit position cnt_after_pop
    wire [BUFW-1:0] ins_word = {{(BUFW-IN_W){1'b0}}, s_tdata} << cnt_after_pop;
    wire [BUFW-1:0] shifted  = buf_q >> pop_amt;

    always @(posedge clk) begin
        if (rst | flush) begin
            buf_q  <= {BUFW{1'b0}};
            cnt_q  <= {CNTW{1'b0}};
            last_q <= 1'b0;
        end else begin
            buf_q <= accept ? (shifted | ins_word) : shifted;
            cnt_q <= cnt_after_pop + (accept ? IN_W[CNTW-1:0] : {CNTW{1'b0}});
            if (accept) last_q <= s_tlast;
        end
    end
endmodule

`default_nettype wire
