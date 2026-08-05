// ============================================================================
// emb_accum - double-buffered pooling accumulator.
//
// This is the engine's datapath.  Three things live here:
//
//   1. the ping-pong staging store (emb_stage_buf), filled a beat at a time by
//      the memory gather;
//   2. LANES reduce lanes (emb_reduce_lane) that fold one staged chunk into the
//      accumulator every clock - so a whole row is folded in CHUNKS cycles,
//      exactly the number of beats the next row's burst takes.  Because fill and
//      fold work on opposite buffers, they run at the same time and the engine
//      retires LANES words per clock instead of stalling for the fetch;
//   3. the drain path, which streams the pooled vector out and, for MEAN, first
//      runs a divide-in-place pass through LANES pipelined dividers.
//
// Setting `single_buf` collapses the two buffers into one logical buffer: a row
// may only be fetched when nothing is staged and nothing is folding.  The
// results are bit-identical, it just takes about twice as long - that is the A/B
// measurement the README quotes for the double-buffering speedup.
//
// The divide-in-place pass is what keeps the drain free of any FIFO: the
// dividers write each quotient back into the accumulator slot its tag came from
// with no backpressure at all, and only then is the vector streamed to the write
// master, which may be stalled arbitrarily by the bus.
// ============================================================================
`include "emb_defs.vh"

module emb_accum #(
    parameter LANES  = 4,
    parameter CHUNKS = 16,
    parameter CW     = 4
) (
    input  wire                 clk,
    input  wire                 rst,

    // ---- per-descriptor setup ------------------------------------------
    input  wire                 clr,          // pulse: start a new bag
    input  wire [1:0]           op,
    input  wire                 single_buf,

    // ---- fill side (memory gather) -------------------------------------
    output wire                 f_avail,      // a staging buffer can take a row
    input  wire                 f_valid,      // one beat of the current row
    input  wire                 f_first,      // this row is the first pooled row
    input  wire [LANES*32-1:0]  f_data,
    output reg                  f_row_done,   // pulse: row fully staged

    // ---- status --------------------------------------------------------
    output wire                 busy,         // staged or folding or draining

    // ---- drain side (write master) -------------------------------------
    input  wire                 d_start,      // pulse: emit the pooled vector
    input  wire [31:0]          d_count,      // rows actually pooled (MEAN divisor)
    output wire                 d_valid,
    input  wire                 d_ready,
    output wire [LANES*32-1:0]  d_data,
    output reg                  d_done        // pulse: last beat accepted
);
    localparam integer DIVLAT = 34;   // emb_divu latency, W + 2 with W = 32

    // ------------------------------------------------------------ storage
    reg [LANES*32-1:0] acc [0:CHUNKS-1];

    reg          fill_buf, red_buf;
    reg [CW-1:0] fill_c,   red_c;
    reg          full0, full1;
    reg          first0, first1;

    wire [LANES*32-1:0] stage_rd;

    emb_stage_buf #(.LANES(LANES), .CHUNKS(CHUNKS), .CW(CW)) u_stage (
        .clk      (clk),
        .wr_en    (f_valid),
        .wr_buf   (fill_buf),
        .wr_chunk (fill_c),
        .wr_data  (f_data),
        .rd_buf   (red_buf),
        .rd_chunk (red_c),
        .rd_data  (stage_rd)
    );

    // ------------------------------------------------------------- drain FSM
    localparam D_IDLE = 2'd0, D_DIV = 2'd1, D_OUT = 2'd2;
    reg [1:0]    dstate;
    reg          zero_mode;
    reg [31:0]   cnt_q;
    reg [CW-1:0] out_c;
    reg [CW:0]   div_issue, div_recv;

    wire drain_idle = (dstate == D_IDLE);

    // ------------------------------------------------------------- fill grant
    wire red_active = (red_c != {CW{1'b0}});
    wire cur_full   = fill_buf ? full1 : full0;
    assign f_avail = drain_idle && (single_buf ? (!full0 && !full1 && !red_active)
                                              : !cur_full);
    assign busy = full0 | full1 | red_active | ~drain_idle;

    // ------------------------------------------------------------- reduce lanes
    wire red_fire = drain_idle && (red_buf ? full1 : full0);
    wire red_first = red_buf ? first1 : first0;

    wire [LANES*32-1:0] acc_rd = acc[red_c];
    wire [LANES*32-1:0] red_res;

    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : g_lane
            emb_reduce_lane u_lane (
                .op    (op),
                .first (red_first),
                .acc   (acc_rd[32*l +: 32]),
                .val   (stage_rd[32*l +: 32]),
                .res   (red_res[32*l +: 32])
            );
        end
    endgenerate

    // ------------------------------------------------------------- MEAN divide
    wire                div_in_valid = (dstate == D_DIV) && (div_issue < CHUNKS);
    wire [CW-1:0]       div_in_tag   = div_issue[CW-1:0];
    wire [LANES*32-1:0] div_num      = acc[div_issue[CW-1:0]];

    wire [LANES-1:0]    dv;
    wire [7:0]          dtag0;
    wire [LANES*32-1:0] dq;

    generate
        for (l = 0; l < LANES; l = l + 1) begin : g_div
            wire [7:0] tg_o;
            emb_divu #(.W(32), .TAGW(8)) u_div (
                .clk       (clk),
                .rst       (rst),
                .in_valid  (div_in_valid),
                .in_num    (div_num[32*l +: 32]),
                .in_den    (cnt_q),
                .in_tag    ({{(8-CW){1'b0}}, div_in_tag}),
                .out_valid (dv[l]),
                .out_q     (dq[32*l +: 32]),
                .out_tag   (tg_o)
            );
            if (l == 0) assign dtag0 = tg_o;
        end
    endgenerate

    // ------------------------------------------------------------- drain output
    assign d_valid = (dstate == D_OUT);
    assign d_data  = zero_mode ? {(LANES*32){1'b0}} : acc[out_c];

    // ------------------------------------------------------------------- control
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            fill_buf   <= 1'b0;
            red_buf    <= 1'b0;
            fill_c     <= {CW{1'b0}};
            red_c      <= {CW{1'b0}};
            full0      <= 1'b0;
            full1      <= 1'b0;
            first0     <= 1'b0;
            first1     <= 1'b0;
            f_row_done <= 1'b0;
            dstate     <= D_IDLE;
            zero_mode  <= 1'b0;
            cnt_q      <= 32'd0;
            out_c      <= {CW{1'b0}};
            div_issue  <= {(CW+1){1'b0}};
            div_recv   <= {(CW+1){1'b0}};
            d_done     <= 1'b0;
        end else begin
            f_row_done <= 1'b0;
            d_done     <= 1'b0;

            if (clr) begin
                fill_buf  <= 1'b0;
                red_buf   <= 1'b0;
                fill_c    <= {CW{1'b0}};
                red_c     <= {CW{1'b0}};
                full0     <= 1'b0;
                full1     <= 1'b0;
                dstate    <= D_IDLE;
                div_issue <= {(CW+1){1'b0}};
                div_recv  <= {(CW+1){1'b0}};
                out_c     <= {CW{1'b0}};
            end else begin
                // ---- fill: place one beat, flip buffers on the last one ----
                if (f_valid) begin
                    if (fill_c == {CW{1'b0}}) begin
                        if (fill_buf) first1 <= f_first;
                        else          first0 <= f_first;
                    end
                    if (fill_c == CHUNKS - 1) begin
                        fill_c     <= {CW{1'b0}};
                        fill_buf   <= ~fill_buf;
                        f_row_done <= 1'b1;
                        if (fill_buf) full1 <= 1'b1;
                        else          full0 <= 1'b1;
                    end else begin
                        fill_c <= fill_c + 1'b1;
                    end
                end

                // ---- fold: one chunk per clock out of the other buffer ----
                if (red_fire) begin
                    acc[red_c] <= red_res;
                    if (red_c == CHUNKS - 1) begin
                        red_c   <= {CW{1'b0}};
                        red_buf <= ~red_buf;
                        if (red_buf) full1 <= 1'b0;
                        else         full0 <= 1'b0;
                    end else begin
                        red_c <= red_c + 1'b1;
                    end
                end

                // ---- drain ----
                case (dstate)
                D_IDLE: begin
                    if (d_start) begin
                        cnt_q     <= d_count;
                        out_c     <= {CW{1'b0}};
                        div_issue <= {(CW+1){1'b0}};
                        div_recv  <= {(CW+1){1'b0}};
                        if (d_count == 32'd0) begin
                            zero_mode <= 1'b1;
                            dstate    <= D_OUT;
                        end else begin
                            zero_mode <= 1'b0;
                            dstate    <= (op == `EMB_OP_MEAN) ? D_DIV : D_OUT;
                        end
                    end
                end

                D_DIV: begin
                    if (div_in_valid) div_issue <= div_issue + 1'b1;
                    if (dv[0]) begin
                        acc[dtag0[CW-1:0]] <= dq;
                        div_recv <= div_recv + 1'b1;
                        if (div_recv == CHUNKS - 1) dstate <= D_OUT;
                    end
                end

                D_OUT: begin
                    if (d_ready) begin
                        if (out_c == CHUNKS - 1) begin
                            out_c  <= {CW{1'b0}};
                            d_done <= 1'b1;
                            dstate <= D_IDLE;
                        end else begin
                            out_c <= out_c + 1'b1;
                        end
                    end
                end

                default: dstate <= D_IDLE;
                endcase
            end
        end
    end

    // keep the accumulator array defined at time zero for the initial fold
    initial begin
        for (i = 0; i < CHUNKS; i = i + 1) acc[i] = {(LANES*32){1'b0}};
    end
endmodule
