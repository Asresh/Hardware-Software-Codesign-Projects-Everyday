// ============================================================================
// p2p_tx - segmentation engine and link transmitter.
//
// Turns one work-queue entry into a sequence of MTU-sized packets on the
// egress AXI4-Stream: two header beats (length/qp/flags/sequence/tag, then the
// destination address) followed by up to MTU_WORDS payload beats read straight
// out of local memory. There is no store-and-forward here - the read master
// runs ahead into an 8-deep staging FIFO and the FIFO drains onto the wire, so
// a word is on the link a couple of cycles after it leaves memory and the
// message length has no bearing on the buffering.
//
// Two things gate the stream, and they are counted separately because they
// mean different things to a runtime:
//   * credits - the peer has no free receive buffer. This is the flow-control
//     loop doing its job; a packet is never launched without a credit in hand,
//     so the receiver can always land what arrives and the link never has to
//     drop and retransmit.
//   * tready  - the wire itself is busy. Nothing to do but wait.
//
// The sequence number is per queue pair and is what makes loss visible at the
// far end. INJECT.SEQ_SKIP deliberately burns one sequence value on the first
// packet of a run, which is how the receiver's gap detection is tested without
// having to corrupt the link.
// ============================================================================
`timescale 1ns/1ps
`include "p2p_defs.vh"

module p2p_tx #(
    parameter MTU_WORDS = 16,
    parameter NUM_QP    = 4,
    parameter RX_BUFS   = 4,
    parameter STAGE_D   = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        abort,
    input  wire [4:0]  credit_lim,
    input  wire        inject_skip,

    // descriptor in
    input  wire        wqe_valid,
    output wire        wqe_ready,
    input  wire [3:0]  wqe_op,
    input  wire [3:0]  wqe_qp,
    input  wire [31:0] wqe_src,
    input  wire [31:0] wqe_dst,
    input  wire [31:0] wqe_len,
    input  wire [7:0]  wqe_tag,

    // shared read channel, agent 1
    output wire        rd_valid,
    output wire [31:0] rd_addr,
    input  wire        rd_ready,
    input  wire        rd_rsp,
    input  wire [31:0] rd_data,
    input  wire        rd_err,

    // credit return from the peer
    input  wire        cr_valid,
    input  wire [3:0]  cr_qp,

    // egress link
    output reg         tx_tvalid,
    output reg  [31:0] tx_tdata,
    output reg         tx_tlast,
    output reg         tx_tuser,
    input  wire        tx_tready,

    output wire        tx_busy,
    output reg  [31:0] pkt_count,
    output reg  [31:0] txw_count,
    output reg  [31:0] cred_stall,
    output reg  [31:0] link_stall,
    output reg  [31:0] mem_stall,
    output reg         bus_err
);

    localparam S_IDLE = 3'd0,
               S_CRED = 3'd1,
               S_H0   = 3'd2,
               S_H1   = 3'd3,
               S_PAY  = 3'd4;

    localparam CW = 5;                      // credit counter width
    localparam QPW = (NUM_QP <= 2) ? 1 : ((NUM_QP <= 4) ? 2 : 3);
    localparam [CW-1:0] CRED_MAX = RX_BUFS[CW-1:0];

    reg [2:0]  st;
    reg [3:0]  op_r, qp_r;
    reg [31:0] src_r, dst_r, rem_r;
    reg [7:0]  tag_r;
    reg        first_r;
    reg [8:0]  pkt_len;
    reg [8:0]  issued, sent;
    reg        inj_armed;

    reg [7:0]  seq  [0:NUM_QP-1];
    reg [CW-1:0] cred [0:NUM_QP-1];
    reg [3:0]  rd_out;

    integer i;

    assign tx_busy = (st != S_IDLE);

    // ------------------------------------------------------- staging FIFO
    wire                  f_full, f_empty;
    wire [31:0]           f_rdata;
    wire [$clog2(STAGE_D):0] f_cnt;
    wire                  f_pop = (st == S_PAY) && !f_empty && tx_tready;

    p2p_fifo #(.W(32), .DEPTH(STAGE_D)) u_stage (
        .clk(clk), .rst_n(rst_n), .flush(start || abort),
        .wr_en(rd_rsp), .wr_data(rd_data),
        .rd_en(f_pop), .rd_data(f_rdata),
        .empty(f_empty), .full(f_full), .count(f_cnt)
    );

    // A read is only issued when its landing slot in the FIFO is already
    // reserved (occupancy + reads already in flight < depth), so returning
    // data never has to stall the shared read channel.
    wire [7:0] occ = f_cnt + rd_out;
    wire reserve_ok = (occ < STAGE_D);

    // Payload fetch starts on the header beats, not on the first payload beat:
    // the packet length is known the moment the credit is taken, so the two
    // header cycles are exactly the memory round trip and the first payload
    // word is in the FIFO by the time the wire is ready for it. Without this
    // the read pipeline drains and refills at every packet boundary, which at
    // MTU 16 costs about a sixth of the link.
    assign rd_valid = ((st == S_H0) || (st == S_H1) || (st == S_PAY)) &&
                      (issued < pkt_len) && reserve_ok;
    assign rd_addr  = src_r + {21'd0, issued, 2'd0};

    // ---------------------------------------------------------- next packet
    wire [8:0] next_len = (rem_r > MTU_WORDS) ? MTU_WORDS[8:0] : rem_r[8:0];
    wire       is_last  = (rem_r <= MTU_WORDS);
    wire [3:0] flags    = (first_r ? `P2P_FLAG_FIRST : 4'h0) |
                          (is_last ? `P2P_FLAG_LAST  : 4'h0) |
                          ((op_r == `P2P_OP_ACCUM) ? `P2P_FLAG_ACCUM : 4'h0);

    assign wqe_ready = (st == S_IDLE) && !abort;

    // Packet bookkeeping rides on the last beat of the packet rather than
    // costing a state of its own - at MTU 16 a dead cycle per packet is 5% of
    // the link.
    wire pkt_done = ((st == S_H1)  && tx_tready && (pkt_len == 9'd0)) ||
                    ((st == S_PAY) && tx_tvalid && tx_tready &&
                     (sent == pkt_len - 9'd1));

    // ------------------------------------------------------------- stream
    always @* begin
        tx_tvalid = 1'b0;
        tx_tdata  = 32'd0;
        tx_tlast  = 1'b0;
        tx_tuser  = 1'b0;
        case (st)
            S_H0: begin
                tx_tvalid = 1'b1;
                tx_tuser  = 1'b1;
                tx_tdata  = {tag_r, seq[qp_r[QPW-1:0]], flags, qp_r, pkt_len[7:0]};
            end
            S_H1: begin
                tx_tvalid = 1'b1;
                tx_tdata  = dst_r;
                tx_tlast  = (pkt_len == 9'd0);
            end
            S_PAY: begin
                tx_tvalid = !f_empty;
                tx_tdata  = f_rdata;
                tx_tlast  = (sent == pkt_len - 9'd1);
            end
            default: ;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; rd_out <= 4'd0; bus_err <= 1'b0;
            pkt_count <= 0; txw_count <= 0;
            cred_stall <= 0; link_stall <= 0; mem_stall <= 0;
            inj_armed <= 1'b0;
            op_r <= 0; qp_r <= 0; src_r <= 0; dst_r <= 0; rem_r <= 0;
            tag_r <= 0; first_r <= 0; pkt_len <= 0; issued <= 0; sent <= 0;
            for (i = 0; i < NUM_QP; i = i + 1) begin
                seq[i]  <= 8'd0;
                cred[i] <= CRED_MAX;
            end
        end else begin
            // ---- credit accounting (return always wins over consumption) ---
            if (cr_valid && (cr_qp < NUM_QP))
                cred[cr_qp[QPW-1:0]] <= cred[cr_qp[QPW-1:0]] + 1'b1;

            case ({rd_valid && rd_ready, rd_rsp})
                2'b10:   rd_out <= rd_out + 4'd1;
                2'b01:   rd_out <= rd_out - 4'd1;
                default: rd_out <= rd_out;
            endcase

            if (rd_valid && rd_ready) issued <= issued + 9'd1;

            if (rd_err) bus_err <= 1'b1;
            if (rd_valid && !rd_ready) mem_stall <= mem_stall + 32'd1;
            if (tx_tvalid && !tx_tready) link_stall <= link_stall + 32'd1;

            if (start) begin
                st <= S_IDLE; rd_out <= 4'd0; bus_err <= 1'b0;
                pkt_count <= 0; txw_count <= 0;
                cred_stall <= 0; link_stall <= 0; mem_stall <= 0;
                inj_armed <= inject_skip;
                for (i = 0; i < NUM_QP; i = i + 1) begin
                    seq[i]  <= 8'd0;
                    cred[i] <= (credit_lim > CRED_MAX) ? CRED_MAX
                                                       : credit_lim[CW-1:0];
                end
            end else if (abort) begin
                st <= S_IDLE; rd_out <= 4'd0;
            end else case (st)
                S_IDLE: begin
                    if (wqe_valid) begin
                        op_r    <= wqe_op;
                        qp_r    <= wqe_qp;
                        src_r   <= wqe_src;
                        dst_r   <= wqe_dst;
                        rem_r   <= wqe_len;
                        tag_r   <= wqe_tag;
                        first_r <= 1'b1;
                        st      <= S_CRED;
                    end
                end

                S_CRED: begin
                    if (cred[qp_r[QPW-1:0]] != {CW{1'b0}}) begin
                        cred[qp_r[QPW-1:0]] <= cred[qp_r[QPW-1:0]] - 1'b1
                                           + ((cr_valid && (cr_qp == qp_r)) ? 1'b1 : 1'b0);
                        pkt_len <= next_len;
                        issued  <= 9'd0;
                        sent    <= 9'd0;
                        st      <= S_H0;
                    end else begin
                        cred_stall <= cred_stall + 32'd1;
                    end
                end

                S_H0: if (tx_tready) st <= S_H1;

                S_H1: if (tx_tready && (pkt_len != 9'd0)) st <= S_PAY;

                S_PAY: begin
                    if (tx_tvalid && tx_tready) begin
                        sent      <= sent + 9'd1;
                        txw_count <= txw_count + 32'd1;
                    end
                end

                default: st <= S_IDLE;
            endcase

            if (pkt_done) begin
                pkt_count <= pkt_count + 32'd1;
                if (inj_armed) begin
                    seq[qp_r[QPW-1:0]] <= seq[qp_r[QPW-1:0]] + 8'd2;
                    inj_armed          <= 1'b0;
                end else begin
                    seq[qp_r[QPW-1:0]] <= seq[qp_r[QPW-1:0]] + 8'd1;
                end
                src_r   <= src_r + {21'd0, pkt_len, 2'd0};
                dst_r   <= dst_r + {21'd0, pkt_len, 2'd0};
                rem_r   <= rem_r - {23'd0, pkt_len};
                first_r <= 1'b0;
                st      <= (rem_r <= {23'd0, pkt_len}) ? S_IDLE : S_CRED;
            end
        end
    end

endmodule
