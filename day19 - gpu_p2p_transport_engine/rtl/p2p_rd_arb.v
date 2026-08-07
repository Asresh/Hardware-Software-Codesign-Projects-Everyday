// ============================================================================
// p2p_rd_arb - round-robin arbiter for the shared AXI4-Lite read channel.
//
// Three agents read memory: the work-queue fetcher (low volume, bursty), the
// transmitter's payload fetch (one word per clock when it can get it), and the
// receiver's read-modify-write path when the opcode is ACCUM. Fixed priority
// would let a long transmit starve the accumulate path, which shows up as the
// link backing up rather than as an obviously wrong answer, so the grant
// rotates.
//
// AXI4-Lite answers in order, so the arbiter does not need transaction IDs -
// it needs the *order it granted in*. That is the tag FIFO: push the winner's
// index when AR goes out, pop it when R comes back, and the response is routed
// to whoever is at the head. Depth covers the master's full outstanding window.
// ============================================================================
`timescale 1ns/1ps

module p2p_rd_arb #(
    parameter TAGD = 8          // power of two, >= read master OUTSTANDING
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,

    // agent 0 - work-queue fetch
    input  wire        a0_valid,
    input  wire [31:0] a0_addr,
    output wire        a0_ready,
    output wire        a0_rsp,
    // agent 1 - transmit payload fetch
    input  wire        a1_valid,
    input  wire [31:0] a1_addr,
    output wire        a1_ready,
    output wire        a1_rsp,
    // agent 2 - receive accumulate fetch
    input  wire        a2_valid,
    input  wire [31:0] a2_addr,
    output wire        a2_ready,
    output wire        a2_rsp,

    // shared read master
    output reg         req_valid,
    output reg  [31:0] req_addr,
    input  wire        req_ready,
    input  wire        rsp_valid
);

    localparam TAW = $clog2(TAGD);

    reg [1:0]     tag  [0:TAGD-1];
    reg [TAW-1:0] t_wr, t_rd;
    reg [TAW:0]   t_cnt;

    wire tag_full = (t_cnt == TAGD);

    // ------------------------------------------------------------ grant
    reg [1:0] rr;               // rotating start of the priority chain
    reg [1:0] sel;
    reg       any;

    always @* begin
        any = 1'b0;
        sel = 2'd0;
        // walk the three agents starting at rr
        if      (rr == 2'd0) begin
            if      (a0_valid) begin sel = 2'd0; any = 1'b1; end
            else if (a1_valid) begin sel = 2'd1; any = 1'b1; end
            else if (a2_valid) begin sel = 2'd2; any = 1'b1; end
        end else if (rr == 2'd1) begin
            if      (a1_valid) begin sel = 2'd1; any = 1'b1; end
            else if (a2_valid) begin sel = 2'd2; any = 1'b1; end
            else if (a0_valid) begin sel = 2'd0; any = 1'b1; end
        end else begin
            if      (a2_valid) begin sel = 2'd2; any = 1'b1; end
            else if (a0_valid) begin sel = 2'd0; any = 1'b1; end
            else if (a1_valid) begin sel = 2'd1; any = 1'b1; end
        end

        req_valid = any && !tag_full;
        case (sel)
            2'd0:    req_addr = a0_addr;
            2'd1:    req_addr = a1_addr;
            default: req_addr = a2_addr;
        endcase
    end

    wire fire = req_valid && req_ready;

    assign a0_ready = fire && (sel == 2'd0);
    assign a1_ready = fire && (sel == 2'd1);
    assign a2_ready = fire && (sel == 2'd2);

    // ------------------------------------------------------------ response
    wire [1:0] head = tag[t_rd];
    assign a0_rsp = rsp_valid && (t_cnt != 0) && (head == 2'd0);
    assign a1_rsp = rsp_valid && (t_cnt != 0) && (head == 2'd1);
    assign a2_rsp = rsp_valid && (t_cnt != 0) && (head == 2'd2);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_wr <= 0; t_rd <= 0; t_cnt <= 0; rr <= 2'd0;
        end else if (flush) begin
            t_wr <= 0; t_rd <= 0; t_cnt <= 0; rr <= 2'd0;
        end else begin
            if (fire) begin
                tag[t_wr] <= sel;
                t_wr      <= t_wr + 1'b1;
                rr        <= (sel == 2'd2) ? 2'd0 : (sel + 2'd1);
            end
            if (rsp_valid && (t_cnt != 0))
                t_rd <= t_rd + 1'b1;

            case ({fire, rsp_valid && (t_cnt != 0)})
                2'b10:   t_cnt <= t_cnt + 1'b1;
                2'b01:   t_cnt <= t_cnt - 1'b1;
                default: t_cnt <= t_cnt;
            endcase
        end
    end

endmodule
