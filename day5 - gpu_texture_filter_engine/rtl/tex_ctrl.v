// -----------------------------------------------------------------------------
// tex_ctrl.v
// The sequencer and wide memory master for the texture-filter engine. On a
// doorbell it walks the destination image row by row:
//
//   S_ROW   - resolve the source rows y0,y0+1 this output row needs; refetch
//             only the ones not already resident (line-buffer reuse).
//   S_LOAD  - stream a source row into the line buffer, one memory word (4
//             pixels) per clock, pipelined so it sustains one beat/cycle.
//   S_PROC  - walk the output row: each clock the x accumulator advances by
//             scale_x, the line buffer returns the 2x2 neighbourhood, the blend
//             datapath produces one pixel, and every fourth pixel is packed into
//             a word and written back. Read (load) and write (store) never occur
//             in the same phase, so one memory port serves both.
//
// Coordinates are produced by accumulation (ux += scale_x, uy += scale_y): no
// multiplier on the per-pixel path, only one small index*stride multiply per row
// for addressing. The free-running cycle counter is latched at completion and
// exposed through the mailbox.
// -----------------------------------------------------------------------------
`default_nettype none

module tex_ctrl #(
    parameter integer PIX_W      = 8,
    parameter integer PPW        = 4,
    parameter integer WORD_W     = PPW*PIX_W,
    parameter integer ADDR_WIDTH = 20,
    parameter integer IDXW       = 16
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // ---- doorbell + descriptor ----
    input  wire                   start,
    input  wire [ADDR_WIDTH-1:0]  src_base,
    input  wire [ADDR_WIDTH-1:0]  dst_base,
    input  wire [15:0]            src_w,
    input  wire [15:0]            src_h,
    input  wire [15:0]            dst_w,
    input  wire [15:0]            dst_h,
    input  wire [31:0]            scale_x,
    input  wire [31:0]            scale_y,

    // ---- datapath coupling ----
    output reg  [31:0]            ux,        // Q16.16 x position (to coord_gen_x)
    output reg  [31:0]            uy,        // Q16.16 y position (to coord_gen_y)
    input  wire [IDXW-1:0]        y0,        // from coord_gen_y
    input  wire [IDXW-1:0]        y1,
    input  wire [PIX_W-1:0]       out_pix,   // from bilinear_blend

    // ---- line-buffer write port ----
    output reg                    lb_wr_en,
    output reg                    lb_wr_row,
    output reg  [IDXW-1:0]        lb_wr_word,
    output reg  [WORD_W-1:0]      lb_wr_data,

    // ---- wide memory master ----
    output reg                    mem_rd_en,
    output reg  [ADDR_WIDTH-1:0]  mem_rd_addr,
    input  wire [WORD_W-1:0]      mem_rd_data,
    output reg                    mem_wr_en,
    output reg  [ADDR_WIDTH-1:0]  mem_wr_addr,
    output reg  [WORD_W-1:0]      mem_wr_data,

    // ---- status ----
    output reg                    busy,
    output reg                    done_set,
    output reg  [31:0]            cycles
);
    localparam [2:0]
        S_IDLE=3'd0, S_SETUP=3'd1, S_ROW=3'd2, S_LOAD=3'd3,
        S_PROC=3'd4, S_ROWEND=3'd5, S_DONE=3'd6;

    reg [2:0]  state;
    reg [31:0] cyc;
    reg [15:0] oy, ox;
    reg [15:0] nw_src, nw_dst;

    reg [IDXW-1:0] cur_top_row, cur_bot_row;
    reg            valid_rows;

    // load pipeline
    reg [IDXW:0]      rd_idx;
    reg               pend;
    reg [IDXW-1:0]    pend_word;
    reg               cur_load_row;      // 0 = top, 1 = bottom
    reg               need_bot_after;
    reg [ADDR_WIDTH-1:0] load_base;
    reg [IDXW-1:0]    load_rowidx;

    reg [IDXW-1:0]    y0_lat, y1_lat;
    reg [ADDR_WIDTH-1:0] dst_row_base;

    // output word packer
    reg [PIX_W-1:0]   b0, b1, b2;

    wire [1:0] phase = ox[1:0];

    // combinational load-target decisions for the current row
    wire need_top = (!valid_rows) || (y0 != cur_top_row);
    wire need_bot = (!valid_rows) || (y1 != cur_bot_row);

    // ---------------- combinational memory / line-buffer outputs ----------------
    always @(*) begin
        mem_rd_en   = 1'b0;  mem_rd_addr = {ADDR_WIDTH{1'b0}};
        mem_wr_en   = 1'b0;  mem_wr_addr = {ADDR_WIDTH{1'b0}};
        mem_wr_data = {WORD_W{1'b0}};
        lb_wr_en    = 1'b0;  lb_wr_row = 1'b0;
        lb_wr_word  = {IDXW{1'b0}}; lb_wr_data = {WORD_W{1'b0}};

        if (state == S_LOAD) begin
            // issue one read per cycle until the row is done ...
            if (rd_idx < {1'b0, nw_src}) begin
                mem_rd_en   = 1'b1;
                mem_rd_addr = load_base + {{(ADDR_WIDTH-IDXW-1){1'b0}}, rd_idx};
            end
            // ... and retire the read issued last cycle into the line buffer
            if (pend) begin
                lb_wr_en   = 1'b1;
                lb_wr_row  = cur_load_row;
                lb_wr_word = pend_word;
                lb_wr_data = mem_rd_data;
            end
        end else if (state == S_PROC) begin
            // pack four filtered pixels, store one word every fourth pixel
            if (phase == 2'd3) begin
                mem_wr_en   = 1'b1;
                mem_wr_addr = dst_row_base + {{(ADDR_WIDTH-14){1'b0}}, ox[15:2]};
                mem_wr_data = {out_pix, b2, b1, b0};
            end
        end
    end

    // ---------------- sequential control ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; busy<=0; done_set<=0; cycles<=0; cyc<=0;
            oy<=0; ox<=0; nw_src<=0; nw_dst<=0;
            cur_top_row<=0; cur_bot_row<=0; valid_rows<=0;
            rd_idx<=0; pend<=0; pend_word<=0; cur_load_row<=0; need_bot_after<=0;
            load_base<=0; load_rowidx<=0; y0_lat<=0; y1_lat<=0; dst_row_base<=0;
            ux<=0; uy<=0; b0<=0; b1<=0; b2<=0;
        end else begin
            done_set <= 1'b0;
            if (busy) cyc <= cyc + 1'b1;

            case (state)
            // -------------------------------------------------------------
            S_IDLE: begin
                if (start) begin
                    busy   <= 1'b1;
                    cyc    <= 0;
                    nw_src <= src_w >> 2;
                    nw_dst <= dst_w >> 2;
                    oy     <= 0;
                    uy     <= 0;
                    valid_rows <= 1'b0;
                    state  <= S_ROW;
                end
            end
            // -------------------------------------------------------------
            S_SETUP: state <= S_ROW;   // reserved; setup folded into S_IDLE
            // -------------------------------------------------------------
            S_ROW: begin
                y0_lat       <= y0;
                y1_lat       <= y1;
                dst_row_base <= dst_base + oy * nw_dst;
                valid_rows   <= 1'b1;
                if (need_top) begin
                    cur_load_row   <= 1'b0;
                    load_rowidx    <= y0;
                    load_base      <= src_base + y0 * nw_src;
                    need_bot_after <= need_bot;
                    rd_idx<=0; pend<=0;
                    state <= S_LOAD;
                end else if (need_bot) begin
                    cur_load_row   <= 1'b1;
                    load_rowidx    <= y1;
                    load_base      <= src_base + y1 * nw_src;
                    need_bot_after <= 1'b0;
                    rd_idx<=0; pend<=0;
                    state <= S_LOAD;
                end else begin
                    ux <= 0; ox <= 0;
                    state <= S_PROC;
                end
            end
            // -------------------------------------------------------------
            S_LOAD: begin
                // advance the read-issue counter and the 1-deep write pipeline
                if (rd_idx < {1'b0, nw_src}) begin
                    rd_idx    <= rd_idx + 1'b1;
                    pend      <= 1'b1;
                    pend_word <= rd_idx[IDXW-1:0];
                end else begin
                    pend <= 1'b0;
                end
                // row fully retired?
                if (rd_idx == {1'b0, nw_src} && !pend) begin
                    if (cur_load_row == 1'b0) begin
                        cur_top_row <= load_rowidx;
                        if (need_bot_after) begin
                            cur_load_row   <= 1'b1;
                            load_rowidx    <= y1_lat;
                            load_base      <= src_base + y1_lat * nw_src;
                            need_bot_after <= 1'b0;
                            rd_idx<=0; pend<=0;
                            state <= S_LOAD;
                        end else begin
                            ux <= 0; ox <= 0;
                            state <= S_PROC;
                        end
                    end else begin
                        cur_bot_row <= load_rowidx;
                        ux <= 0; ox <= 0;
                        state <= S_PROC;
                    end
                end
            end
            // -------------------------------------------------------------
            S_PROC: begin
                case (phase)
                    2'd0: b0 <= out_pix;
                    2'd1: b1 <= out_pix;
                    2'd2: b2 <= out_pix;
                    default: ;                 // phase 3 writes combinationally
                endcase
                ux <= ux + scale_x;
                ox <= ox + 1'b1;
                if (ox == dst_w - 1) state <= S_ROWEND;
            end
            // -------------------------------------------------------------
            S_ROWEND: begin
                uy <= uy + scale_y;
                oy <= oy + 1'b1;
                if (oy == dst_h - 1) state <= S_DONE;
                else                 state <= S_ROW;
            end
            // -------------------------------------------------------------
            S_DONE: begin
                cycles   <= cyc;
                done_set <= 1'b1;
                busy     <= 1'b0;
                state    <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
