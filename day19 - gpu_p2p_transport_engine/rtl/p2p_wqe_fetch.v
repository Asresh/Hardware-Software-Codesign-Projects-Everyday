// ============================================================================
// p2p_wqe_fetch - work-queue ring reader and descriptor validator.
//
// The host posts 8-word work-queue entries into a ring in shared memory and
// rings the doorbell; from there the engine owns the ring. Each entry is
// pulled with eight pipelined reads (address ahead of data, so a whole
// descriptor costs about as long as one memory round trip rather than eight),
// then validated in a single cycle against a fixed error priority before it is
// handed to the transmitter.
//
// Validation lives here, in front of the datapath, for the same reason a NIC
// validates a WQE before it touches the wire: a malformed descriptor must cost
// one control decision, not a half-sent packet that the peer then has to
// unpick. A rejected entry is counted and skipped and the ring keeps draining,
// so one bad descriptor from one process does not take the link down.
// ============================================================================
`timescale 1ns/1ps
`include "p2p_defs.vh"

module p2p_wqe_fetch #(
    parameter NUM_QP        = 4,
    parameter MAX_MSG_WORDS = 4096
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire        abort,
    input  wire [31:0] wq_base,
    input  wire [31:0] wq_count,
    input  wire [31:0] mem_limit,

    // shared read channel, agent 0
    output wire        rd_valid,
    output wire [31:0] rd_addr,
    input  wire        rd_ready,
    input  wire        rd_rsp,
    input  wire [31:0] rd_data,
    input  wire        rd_err,

    // descriptor handoff to the transmitter
    output reg         wqe_valid,
    input  wire        wqe_ready,
    output wire [3:0]  wqe_op,
    output wire [3:0]  wqe_qp,
    output wire [31:0] wqe_src,
    output wire [31:0] wqe_dst,
    output wire [31:0] wqe_len,
    output wire [7:0]  wqe_tag,

    output reg         fetch_done,
    output reg         err_pulse,
    output reg  [3:0]  err_code,
    output reg  [31:0] err_index,
    output reg  [31:0] accepted
);

    localparam S_IDLE  = 3'd0,
               S_FETCH = 3'd1,
               S_CHECK = 3'd2,
               S_EMIT  = 3'd3,
               S_NEXT  = 3'd4,
               S_DONE  = 3'd5;

    reg [2:0]  st;
    reg [31:0] idx;
    reg [3:0]  iss, rcv;
    reg [31:0] w [0:7];
    reg        bus_err;

    assign wqe_op  = w[0][3:0];
    assign wqe_qp  = w[0][7:4];
    assign wqe_src = w[1];
    assign wqe_dst = w[2];
    assign wqe_len = w[3];
    assign wqe_tag = w[4][7:0];

    assign rd_valid = (st == S_FETCH) && (iss < 4'd8);
    assign rd_addr  = wq_base + {idx[26:0], 5'd0} + {26'd0, iss[2:0], 2'd0};

    // ---------------------------------------------------------- validation
    // Fixed priority so the reported code is a property of the descriptor and
    // not of the order the checks happen to be written in.
    wire [63:0] src_end = {32'd0, w[1]} + ({32'd0, w[3]} << 2);
    wire [63:0] dst_end = {32'd0, w[2]} + ({32'd0, w[3]} << 2);

    reg [3:0] chk;
    always @* begin
        if      ((w[0][3:0] != `P2P_OP_WRITE) &&
                 (w[0][3:0] != `P2P_OP_ACCUM))         chk = `P2P_ERR_OP;
        else if (w[0][7:4] >= NUM_QP[3:0])              chk = `P2P_ERR_QP;
        else if (w[3] > MAX_MSG_WORDS)                  chk = `P2P_ERR_LEN;
        else if ((w[1][1:0] != 2'b00) ||
                 (w[2][1:0] != 2'b00))                  chk = `P2P_ERR_ALIGN;
        else if ((src_end > {32'd0, mem_limit}) ||
                 (dst_end > {32'd0, mem_limit}))        chk = `P2P_ERR_RANGE;
        else                                            chk = `P2P_ERR_NONE;
    end

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; idx <= 32'd0; iss <= 4'd0; rcv <= 4'd0;
            wqe_valid <= 1'b0; fetch_done <= 1'b0;
            err_pulse <= 1'b0; err_code <= `P2P_ERR_NONE; err_index <= 32'd0;
            accepted <= 32'd0; bus_err <= 1'b0;
            for (k = 0; k < 8; k = k + 1) w[k] <= 32'd0;
        end else begin
            err_pulse <= 1'b0;

            if (abort) begin
                st <= S_IDLE; wqe_valid <= 1'b0; fetch_done <= 1'b0;
            end else case (st)
                S_IDLE: begin
                    if (start) begin
                        idx <= 32'd0; iss <= 4'd0; rcv <= 4'd0;
                        accepted <= 32'd0; bus_err <= 1'b0;
                        err_code <= `P2P_ERR_NONE; err_index <= 32'd0;
                        fetch_done <= 1'b0;
                        st <= (wq_count == 32'd0) ? S_DONE : S_FETCH;
                    end
                end

                S_FETCH: begin
                    if (rd_valid && rd_ready) iss <= iss + 4'd1;
                    if (rd_rsp) begin
                        w[rcv[2:0]] <= rd_data;
                        rcv         <= rcv + 4'd1;
                        if (rd_err) bus_err <= 1'b1;
                        if (rcv == 4'd7) st <= S_CHECK;
                    end
                end

                S_CHECK: begin
                    if (bus_err) begin
                        err_pulse <= 1'b1;
                        if (err_code == `P2P_ERR_NONE) begin
                            err_code  <= `P2P_ERR_BUS;
                            err_index <= idx;
                        end
                        st <= S_DONE;
                    end else if (chk != `P2P_ERR_NONE) begin
                        err_pulse <= 1'b1;
                        if (err_code == `P2P_ERR_NONE) begin
                            err_code  <= chk;
                            err_index <= idx;
                        end
                        st <= S_NEXT;
                    end else begin
                        wqe_valid <= 1'b1;
                        st        <= S_EMIT;
                    end
                end

                S_EMIT: begin
                    if (wqe_ready) begin
                        wqe_valid <= 1'b0;
                        accepted  <= accepted + 32'd1;
                        st        <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    iss <= 4'd0; rcv <= 4'd0;
                    if (idx + 32'd1 >= wq_count) st <= S_DONE;
                    else begin
                        idx <= idx + 32'd1;
                        st  <= S_FETCH;
                    end
                end

                S_DONE: begin
                    fetch_done <= 1'b1;
                    if (start) begin
                        idx <= 32'd0; iss <= 4'd0; rcv <= 4'd0;
                        accepted <= 32'd0; bus_err <= 1'b0;
                        err_code <= `P2P_ERR_NONE; err_index <= 32'd0;
                        fetch_done <= 1'b0;
                        st <= (wq_count == 32'd0) ? S_DONE : S_FETCH;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
