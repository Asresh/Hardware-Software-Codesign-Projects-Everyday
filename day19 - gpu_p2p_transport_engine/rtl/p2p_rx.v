// ============================================================================
// p2p_rx - packet receiver, reassembly, commit and completion posting.
//
// The receive side is store-and-forward, and that is the whole reason credits
// exist: there are RX_BUFS packet buffers of MTU_WORDS each, a credit *is* a
// buffer, and the transmitter is not allowed to put a packet on the wire
// without holding one. So an arriving packet always has somewhere to land, the
// link never has to drop and retransmit, and the buffer pool - not a timeout -
// is what bounds how far ahead the sender may run.
//
// Landing and committing are decoupled: beats stream into one slot while an
// earlier slot is drained to memory, and slots are allocated and freed in
// order, so what memory sees is exactly the order the packets arrived in. That
// in-order retirement is what makes the final memory image a function of the
// descriptor ring alone and not of how the bus happened to be scheduled.
//
// Two commit modes share the drain path:
//   WRITE  - one memory write per word, one word per clock.
//   ACCUM  - read the destination word, add the payload word (32-bit wrapping,
//            two's complement) and write it back. This is the reduce half of a
//            reduce-scatter done *on the link* instead of in a kernel: the
//            receiving GPU never has to launch anything to fold a peer's
//            partial sum into its shard. It costs a memory round trip per
//            word, which is exactly what the two rates in the results table
//            are measuring.
//
// A sequence gap is detected on the header beat, counted, and the offending
// packet is discarded whole - never half-committed - with the expected
// sequence resynchronised so the queue pair keeps running. The credit is
// returned either way, because a credit the receiver swallows is a credit the
// sender waits on forever. Credit returns are per-queue-pair pending counts
// rather than a queue, so a discard and a slot release landing on the same
// clock both survive.
// ============================================================================
`timescale 1ns/1ps
`include "p2p_defs.vh"

module p2p_rx #(
    parameter MTU_WORDS = 16,
    parameter NUM_QP    = 4,
    parameter RX_BUFS   = 4         // power of two
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        abort,
    input  wire [31:0] cq_base,

    // ingress link
    input  wire        rx_tvalid,
    input  wire [31:0] rx_tdata,
    input  wire        rx_tlast,
    input  wire        rx_tuser,
    output wire        rx_tready,

    // shared read channel, agent 2 (accumulate path)
    output wire        rd_valid,
    output wire [31:0] rd_addr,
    input  wire        rd_ready,
    input  wire        rd_rsp,
    input  wire [31:0] rd_data,
    input  wire        rd_err,

    // dedicated write master
    output wire        wr_valid,
    output wire [31:0] wr_addr,
    output wire [31:0] wr_data,
    input  wire        wr_ready,
    input  wire        wr_err,
    input  wire        wr_idle,        // no write transaction still in flight

    // credit return towards the peer transmitter
    output wire        cr_valid,
    output wire [3:0]  cr_qp,
    input  wire        cr_ready,

    output wire        rx_busy,
    output reg  [31:0] rxw_count,
    output reg  [31:0] cqe_count,
    output reg  [31:0] seqerr_count,
    output reg  [31:0] frm_count,
    output reg  [31:0] pkts_retired,
    output reg  [31:0] mem_stall,
    output reg         bus_err
);

    localparam QPW = (NUM_QP  <= 2) ? 1 : ((NUM_QP  <= 4) ? 2 : 3);
    localparam SW  = (RX_BUFS <= 2) ? 1 : ((RX_BUFS <= 4) ? 2 : 3);

    localparam R_H0 = 2'd0, R_H1 = 2'd1, R_PAY = 2'd2;
    localparam D_IDLE = 3'd0, D_WR = 3'd1, D_ACC = 3'd2,
               D_FIN  = 3'd5, D_CQ = 3'd6;
    localparam ACCD = 8;            // depth of the accumulate result FIFO

    // ------------------------------------------------------- receive state
    reg  [1:0]  rs;
    reg  [7:0]  p_len, p_seq, p_tag;
    reg  [3:0]  p_qp, p_flags;
    reg  [31:0] p_dst;
    reg         p_drop;
    reg  [7:0]  widx;
    reg  [7:0]  exp_seq [0:NUM_QP-1];

    // ------------------------------------------------------- buffer pool
    reg  [31:0] pbuf     [0:RX_BUFS*MTU_WORDS-1];
    reg  [31:0] md_dst   [0:RX_BUFS-1];
    reg  [7:0]  md_len   [0:RX_BUFS-1];
    reg  [3:0]  md_flags [0:RX_BUFS-1];
    reg  [3:0]  md_qp    [0:RX_BUFS-1];
    reg  [7:0]  md_seq   [0:RX_BUFS-1];
    reg  [7:0]  md_tag   [0:RX_BUFS-1];

    reg  [SW-1:0] alloc_ptr, drain_ptr;
    reg  [SW:0]   slot_cnt;

    // ------------------------------------------------------- drain state
    reg  [2:0]  ds;
    reg  [7:0]  k, kr, kd;
    reg  [31:0] d_dst;
    reg  [7:0]  d_len, d_seq, d_tag;
    reg  [3:0]  d_flags, d_qp;
    reg  [1:0]  cqw;
    reg  [31:0] cqe_idx;
    reg  [31:0] msg_bytes [0:NUM_QP-1];

    // ------------------------------------------------------- credit return
    reg  [4:0] pend [0:NUM_QP-1];
    reg  [3:0] emit_qp;
    reg        emit_any;

    integer i, j;

    always @* begin
        emit_any = 1'b0;
        emit_qp  = 4'd0;
        for (j = NUM_QP-1; j >= 0; j = j - 1)
            if (pend[j] != 5'd0) begin
                emit_any = 1'b1;
                emit_qp  = j[3:0];
            end
    end

    assign cr_valid = emit_any;
    assign cr_qp    = emit_qp;
    wire   cr_fire  = cr_valid && cr_ready;

    // ------------------------------------------------------- stream accept
    wire have_slot = (slot_cnt < RX_BUFS);
    assign rx_tready = (rs == R_H0) ? have_slot : 1'b1;
    wire   beat = rx_tvalid && rx_tready;
    wire [QPW-1:0] h_qp = rx_tdata[11:8];

    // ------------------------------------------------------- drain outputs
    wire        acc_mode = (d_flags & `P2P_FLAG_ACCUM) != 4'd0;
    wire [31:0] pay_word = pbuf[drain_ptr * MTU_WORDS + (acc_mode ? kd : k)];

    // Accumulate is pipelined rather than a lock-step read-add-write per word:
    // destination reads are issued as far ahead as the result FIFO has room
    // for, the adder folds each returning word against its payload word, and
    // the write channel drains the FIFO independently. Reads and writes are
    // separate AXI channels, so the fold costs read bandwidth, not latency.
    wire        af_empty, af_full;
    wire [31:0] af_rdata;
    wire [$clog2(ACCD):0] af_cnt;
    wire        af_push = (ds == D_ACC) && rd_rsp;
    wire        af_pop;
    wire [7:0]  acc_inflight = kr - kd;
    wire        acc_room = ((af_cnt + acc_inflight) < ACCD);

    p2p_fifo #(.W(32), .DEPTH(ACCD)) u_acc (
        .clk(clk), .rst_n(rst_n), .flush(start || abort || (ds == D_IDLE)),
        .wr_en(af_push), .wr_data(rd_data + pay_word),
        .rd_en(af_pop), .rd_data(af_rdata),
        .empty(af_empty), .full(af_full), .count(af_cnt)
    );

    reg [31:0] cq_word;
    always @* begin
        case (cqw)
            2'd0:    cq_word = {16'd0,
                                ((d_flags & `P2P_FLAG_ACCUM) ? 4'd1 : 4'd0),
                                d_qp, 8'd0};                 // status = 0
            2'd1:    cq_word = {24'd0, d_tag};
            2'd2:    cq_word = msg_bytes[d_qp[QPW-1:0]];
            default: cq_word = {24'd0, d_seq};
        endcase
    end

    assign rd_valid = (ds == D_ACC) && (kr < d_len) && acc_room;
    assign rd_addr  = d_dst + {22'd0, kr, 2'd0};

    wire [31:0] cq_addr = cq_base + (cqe_idx << 4) + {28'd0, cqw, 2'd0};

    assign wr_valid = (ds == D_WR) || (ds == D_CQ) ||
                      ((ds == D_ACC) && !af_empty);
    assign wr_addr  = (ds == D_CQ) ? cq_addr : (d_dst + {22'd0, k, 2'd0});
    assign wr_data  = (ds == D_CQ)  ? cq_word :
                      (ds == D_ACC) ? af_rdata : pay_word;
    assign af_pop   = (ds == D_ACC) && !af_empty && wr_ready;

    assign rx_busy = (rs != R_H0) || (ds != D_IDLE) || (slot_cnt != 0) ||
                     emit_any;

    // ------------------------------------------------------------- sequencer
    reg       alloc_fire, free_fire;
    reg       ret_a, ret_b;
    reg [3:0] ret_a_qp, ret_b_qp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || start || abort) begin
            rs <= R_H0; ds <= D_IDLE;
            alloc_ptr <= 0; drain_ptr <= 0; slot_cnt <= 0;
            widx <= 0; k <= 0; kr <= 0; kd <= 0; cqw <= 0; cqe_idx <= 0;
            rxw_count <= 0; cqe_count <= 0; seqerr_count <= 0; frm_count <= 0;
            pkts_retired <= 0; mem_stall <= 0; bus_err <= 1'b0;
            p_len <= 0; p_seq <= 0; p_tag <= 0; p_qp <= 0; p_flags <= 0;
            p_dst <= 0; p_drop <= 0;
            d_dst <= 0; d_len <= 0; d_flags <= 0; d_qp <= 0;
            d_seq <= 0; d_tag <= 0;
            for (i = 0; i < NUM_QP; i = i + 1) begin
                exp_seq[i]   <= 8'd0;
                msg_bytes[i] <= 32'd0;
                pend[i]      <= 5'd0;
            end
        end else begin
            alloc_fire = 1'b0; free_fire = 1'b0;
            ret_a = 1'b0; ret_b = 1'b0;
            ret_a_qp = 4'd0; ret_b_qp = 4'd0;

            if (wr_err || rd_err) bus_err <= 1'b1;
            if (wr_valid && !wr_ready) mem_stall <= mem_stall + 32'd1;
            if (rd_valid && !rd_ready) mem_stall <= mem_stall + 32'd1;

            // ================================================ receive FSM
            case (rs)
                R_H0: if (beat) begin
                    if (!rx_tuser) frm_count <= frm_count + 32'd1;
                    p_len   <= rx_tdata[7:0];
                    p_qp    <= rx_tdata[11:8];
                    p_flags <= rx_tdata[15:12];
                    p_seq   <= rx_tdata[23:16];
                    p_tag   <= rx_tdata[31:24];
                    if (rx_tdata[23:16] != exp_seq[h_qp]) begin
                        p_drop       <= 1'b1;
                        seqerr_count <= seqerr_count + 32'd1;
                    end else begin
                        p_drop <= 1'b0;
                    end
                    exp_seq[h_qp] <= rx_tdata[23:16] + 8'd1;
                    widx <= 8'd0;
                    rs   <= R_H1;
                end

                R_H1: if (beat) begin
                    if (rx_tuser) frm_count <= frm_count + 32'd1;
                    p_dst <= rx_tdata;
                    if (p_len == 8'd0) begin
                        if (!p_drop) begin
                            md_dst[alloc_ptr]   <= rx_tdata;
                            md_len[alloc_ptr]   <= 8'd0;
                            md_flags[alloc_ptr] <= p_flags;
                            md_qp[alloc_ptr]    <= p_qp;
                            md_seq[alloc_ptr]   <= p_seq;
                            md_tag[alloc_ptr]   <= p_tag;
                            alloc_ptr  <= alloc_ptr + 1'b1;
                            alloc_fire = 1'b1;
                        end else begin
                            ret_a = 1'b1; ret_a_qp = p_qp;
                        end
                        rs <= R_H0;
                    end else begin
                        rs <= R_PAY;
                    end
                end

                R_PAY: if (beat) begin
                    if (rx_tuser) frm_count <= frm_count + 32'd1;
                    if (!p_drop)
                        pbuf[alloc_ptr * MTU_WORDS + widx] <= rx_tdata;
                    widx <= widx + 8'd1;
                    if (widx == p_len - 8'd1) begin
                        if (!p_drop) begin
                            md_dst[alloc_ptr]   <= p_dst;
                            md_len[alloc_ptr]   <= p_len;
                            md_flags[alloc_ptr] <= p_flags;
                            md_qp[alloc_ptr]    <= p_qp;
                            md_seq[alloc_ptr]   <= p_seq;
                            md_tag[alloc_ptr]   <= p_tag;
                            alloc_ptr  <= alloc_ptr + 1'b1;
                            alloc_fire = 1'b1;
                        end else begin
                            ret_a = 1'b1; ret_a_qp = p_qp;
                        end
                        rs <= R_H0;
                    end
                end

                default: rs <= R_H0;
            endcase

            // ================================================== drain FSM
            case (ds)
                // An ACCUM packet reads the destination it is about to fold
                // into, so it must not start until every write of the previous
                // packet has been acknowledged - otherwise two accumulates
                // onto the same region could read stale data and the result
                // would depend on how deep the write pipeline happened to be.
                // Plain writes need no such gate: the write channel is
                // in-order all the way to memory.
                D_IDLE: if ((slot_cnt != 0) &&
                            (wr_idle ||
                             !(md_flags[drain_ptr] & `P2P_FLAG_ACCUM))) begin
                    d_dst   <= md_dst[drain_ptr];
                    d_len   <= md_len[drain_ptr];
                    d_flags <= md_flags[drain_ptr];
                    d_qp    <= md_qp[drain_ptr];
                    d_seq   <= md_seq[drain_ptr];
                    d_tag   <= md_tag[drain_ptr];
                    k <= 8'd0; kr <= 8'd0; kd <= 8'd0;
                    if (md_len[drain_ptr] == 8'd0)                ds <= D_FIN;
                    else if (md_flags[drain_ptr] & `P2P_FLAG_ACCUM) ds <= D_ACC;
                    else                                          ds <= D_WR;
                end

                D_WR: if (wr_ready) begin
                    rxw_count <= rxw_count + 32'd1;
                    k <= k + 8'd1;
                    if (k == d_len - 8'd1) ds <= D_FIN;
                end

                D_ACC: begin
                    if (rd_valid && rd_ready) kr <= kr + 8'd1;
                    if (af_push)              kd <= kd + 8'd1;
                    if (wr_valid && wr_ready) begin
                        rxw_count <= rxw_count + 32'd1;
                        k <= k + 8'd1;
                        if (k == d_len - 8'd1) ds <= D_FIN;
                    end
                end

                D_FIN: begin
                    msg_bytes[d_qp[QPW-1:0]] <=
                        msg_bytes[d_qp[QPW-1:0]] + {22'd0, d_len, 2'd0};
                    cqw <= 2'd0;
                    if (d_flags & `P2P_FLAG_LAST) begin
                        ds <= D_CQ;
                    end else begin
                        ds           <= D_IDLE;
                        drain_ptr <= drain_ptr + 1'b1;
                        free_fire = 1'b1;
                        ret_b     = 1'b1; ret_b_qp = d_qp;
                    end
                end

                D_CQ: if (wr_ready) begin
                    cqw <= cqw + 2'd1;
                    if (cqw == 2'd3) begin
                        cqe_count <= cqe_count + 32'd1;
                        cqe_idx   <= cqe_idx + 32'd1;
                        msg_bytes[d_qp[QPW-1:0]] <= 32'd0;
                        drain_ptr <= drain_ptr + 1'b1;
                        free_fire = 1'b1;
                        ret_b     = 1'b1; ret_b_qp = d_qp;
                        ds <= D_IDLE;
                    end
                end

                default: ds <= D_IDLE;
            endcase

            // ---- slot occupancy ------------------------------------------
            case ({alloc_fire, free_fire})
                2'b10:   slot_cnt <= slot_cnt + 1'b1;
                2'b01:   slot_cnt <= slot_cnt - 1'b1;
                default: slot_cnt <= slot_cnt;
            endcase

            // A discard and a slot release can land on the same clock, so the
            // retirement count is the sum of the two events rather than two
            // separate increments - one of which the other would overwrite.
            pkts_retired <= pkts_retired
                          + ((ret_a ? 32'd1 : 32'd0) + (ret_b ? 32'd1 : 32'd0));

            // ---- credit return pending counts ----------------------------
            for (i = 0; i < NUM_QP; i = i + 1)
                pend[i] <= pend[i]
                         + ((ret_a && (ret_a_qp == i[3:0])) ? 5'd1 : 5'd0)
                         + ((ret_b && (ret_b_qp == i[3:0])) ? 5'd1 : 5'd0)
                         - ((cr_fire && (emit_qp == i[3:0])) ? 5'd1 : 5'd0);
        end
    end

endmodule
