// ============================================================================
// emb_core - descriptor-ring walker and memory gather sequencer.
//
// Walks a host-built ring of 8-word descriptors, and for each one:
//
//   1. fetches the descriptor  (DESC_WORDS/LANES beats),
//   2. fetches the whole bag of indices into a local index buffer
//      (ceil(num_idx/LANES) beats) so the row gather never has to interleave
//      pointer loads with data loads,
//   3. classifies every index against this device's shard window - a hit is
//      gathered as one CHUNKS-beat burst into the free staging buffer, a miss
//      belongs to a peer shard and is skipped (counted, not an error), an index
//      past the end of the global table is an error,
//   4. waits for the pooling accumulator to drain the last staged row, then
//      streams the pooled vector out as one CHUNKS-beat write burst.
//
// Row bursts are issued back to back as fast as staging buffers free up; the
// fold of row i happens inside the burst of row i+1, which is where the
// throughput comes from.  A bus error or a wedged slave sets the sticky bus
// error, aborts the walk and still reports completion, so the ring never hangs.
// ============================================================================
`include "emb_defs.vh"

module emb_core #(
    parameter DIM     = `EMB_DIM,
    parameter LANES   = `EMB_LANES,
    parameter MAX_BAG = `EMB_MAX_BAG,
    parameter CHUNKS  = DIM / LANES,
    parameter CW      = 4,
    parameter LOG2L   = 2,
    parameter AW      = 32,
    parameter WDOG    = `EMB_WDOG
) (
    input  wire            clk,
    input  wire            rst,

    // ---- control / configuration (from the register file) ---------------
    input  wire            start,          // pulse
    input  wire            single_buf,
    input  wire [31:0]     desc_base,      // word offsets into device memory
    input  wire [31:0]     desc_count,
    input  wire [31:0]     idx_base,
    input  wire [31:0]     tab_base,
    input  wire [31:0]     out_base,
    input  wire [31:0]     shard_lo,
    input  wire [31:0]     shard_hi,
    input  wire [31:0]     tab_rows,

    output reg             busy,
    output reg             fin,            // pulse: whole ring retired
    output reg             err_baglen,     // sticky
    output reg             err_index,      // sticky
    output reg             err_bus,        // sticky

    // ---- statistics pulses ---------------------------------------------
    output reg             ev_desc,
    output reg             ev_idx,
    output reg             ev_local,
    output reg             ev_remote,
    output reg             ev_invalid,

    // ---- read master request / stream ----------------------------------
    output reg             rd_req_valid,
    input  wire            rd_req_ready,
    output reg  [AW-1:0]   rd_req_addr,
    output reg  [7:0]      rd_req_len,
    input  wire            rd_d_valid,
    output wire            rd_d_ready,
    input  wire [LANES*32-1:0] rd_d_data,
    input  wire            rd_d_last,
    input  wire            rd_err,
    input  wire            rd_timeout,
    input  wire            rd_busy,

    // ---- write master request ------------------------------------------
    output reg             wr_req_valid,
    input  wire            wr_req_ready,
    output reg  [AW-1:0]   wr_req_addr,
    output reg  [7:0]      wr_req_len,
    input  wire            wr_done,
    input  wire            wr_err,
    input  wire            wr_timeout,
    input  wire            wr_busy,

    // ---- accumulator handshake -----------------------------------------
    output reg             ac_clr,
    output wire            ac_f_valid,
    output reg             ac_f_first,
    output wire [LANES*32-1:0] ac_f_data,
    input  wire            ac_f_avail,
    input  wire            ac_busy,
    output reg             ac_d_start,
    output reg  [31:0]     ac_d_count,
    output wire [1:0]      ac_op           // pooling opcode of the live descriptor
);
    localparam integer DESC_BEATS = `EMB_DESC_WORDS / LANES;
    localparam integer IDXBUF_W   = 32 * LANES;

    localparam C_IDLE      = 4'd0,
               C_DESC_REQ  = 4'd1,
               C_DESC_DATA = 4'd2,
               C_IDX_REQ   = 4'd3,
               C_IDX_DATA  = 4'd4,
               C_ROW       = 4'd5,
               C_ROW_REQ   = 4'd6,
               C_ROW_DATA  = 4'd7,
               C_FLUSH     = 4'd8,
               C_DRAIN     = 4'd9,
               C_DRAIN_W   = 4'd10,
               C_NEXT      = 4'd11,
               C_ABORT     = 4'd12,
               C_FIN       = 4'd13;

    reg [3:0]  state;
    reg [31:0] desc_i;

    // descriptor fields
    reg [31:0] d_op, d_num, d_idxoff, d_dstoff;
    reg [$clog2(`EMB_DESC_WORDS)+1:0] desc_w;   // words collected so far

    // bag index buffer
    reg [31:0] idxbuf [0:MAX_BAG-1];
    reg [31:0] idx_w;      // words collected so far
    reg [31:0] j;          // index being classified
    reg [31:0] cnt;        // rows actually pooled on this device
    reg [31:0] abort_wd;

    wire [31:0] cur_ix = idxbuf[j[$clog2(MAX_BAG)-1:0]];

    assign ac_op = d_op[1:0];

    assign rd_d_ready = (state == C_DESC_DATA) || (state == C_IDX_DATA) ||
                        (state == C_ROW_DATA) || (state == C_ABORT);
    assign ac_f_valid = (state == C_ROW_DATA) && rd_d_valid;
    assign ac_f_data  = rd_d_data;

    wire bus_bad = rd_err | rd_timeout | wr_err | wr_timeout;

    // ceil(num_idx / LANES) beats for the index list
    wire [31:0] idx_beats = (d_num + LANES - 1) >> LOG2L;

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            state        <= C_IDLE;
            busy         <= 1'b0;
            fin          <= 1'b0;
            err_baglen   <= 1'b0;
            err_index    <= 1'b0;
            err_bus      <= 1'b0;
            ev_desc      <= 1'b0;
            ev_idx       <= 1'b0;
            ev_local     <= 1'b0;
            ev_remote    <= 1'b0;
            ev_invalid   <= 1'b0;
            rd_req_valid <= 1'b0;
            rd_req_addr  <= {AW{1'b0}};
            rd_req_len   <= 8'd0;
            wr_req_valid <= 1'b0;
            wr_req_addr  <= {AW{1'b0}};
            wr_req_len   <= 8'd0;
            ac_clr       <= 1'b0;
            ac_f_first   <= 1'b0;
            ac_d_start   <= 1'b0;
            ac_d_count   <= 32'd0;
            desc_i       <= 32'd0;
            desc_w       <= 0;
            idx_w        <= 32'd0;
            j            <= 32'd0;
            cnt          <= 32'd0;
            abort_wd     <= 32'd0;
        end else begin
            // single-cycle pulses
            fin        <= 1'b0;
            ev_desc    <= 1'b0;
            ev_idx     <= 1'b0;
            ev_local   <= 1'b0;
            ev_remote  <= 1'b0;
            ev_invalid <= 1'b0;
            ac_clr     <= 1'b0;
            ac_d_start <= 1'b0;

            if (rd_req_valid && rd_req_ready) rd_req_valid <= 1'b0;
            if (wr_req_valid && wr_req_ready) wr_req_valid <= 1'b0;

            // a bus fault anywhere aborts the walk but never hangs it
            if (bus_bad && state != C_IDLE && state != C_FIN) begin
                err_bus <= 1'b1;
                state   <= C_ABORT;
                abort_wd <= 32'd0;
            end else begin
            case (state)
            // ------------------------------------------------------ idle
            C_IDLE: begin
                if (start) begin
                    desc_i     <= 32'd0;
                    busy       <= 1'b1;
                    err_baglen <= 1'b0;
                    err_index  <= 1'b0;
                    err_bus    <= 1'b0;
                    state      <= (desc_count == 32'd0) ? C_FIN : C_DESC_REQ;
                end
            end

            // ------------------------------------------- descriptor fetch
            C_DESC_REQ: begin
                if (rd_req_ready && !rd_req_valid) begin
                    rd_req_addr  <= (desc_base + desc_i * `EMB_DESC_WORDS) << 2;
                    rd_req_len   <= DESC_BEATS - 1;
                    rd_req_valid <= 1'b1;
                    desc_w       <= 0;
                    state        <= C_DESC_DATA;
                end
            end

            C_DESC_DATA: begin
                if (rd_d_valid) begin
                    for (k = 0; k < LANES; k = k + 1) begin
                        case (desc_w + k)
                        0: d_op     <= rd_d_data[32*k +: 32];
                        1: d_num    <= rd_d_data[32*k +: 32];
                        2: d_idxoff <= rd_d_data[32*k +: 32];
                        3: d_dstoff <= rd_d_data[32*k +: 32];
                        default: ;   // words 4..7 reserved
                        endcase
                    end
                    desc_w <= desc_w + LANES;
                    if (rd_d_last) begin
                        ev_desc <= 1'b1;
                        ac_clr  <= 1'b1;
                        cnt     <= 32'd0;
                        j       <= 32'd0;
                        idx_w   <= 32'd0;
                        state   <= C_IDX_REQ;
                    end
                end
            end

            // --------------------------------------------- bag validation
            C_IDX_REQ: begin
                if (d_num > MAX_BAG) begin
                    // the index buffer cannot hold this bag: reject it whole
                    err_baglen <= 1'b1;
                    state      <= C_NEXT;
                end else if (d_num == 32'd0) begin
                    // empty bag: emit a zero vector, which is what an
                    // all-to-all reduce downstream expects for "no rows here"
                    state <= C_FLUSH;
                end else if (rd_req_ready && !rd_req_valid) begin
                    rd_req_addr  <= (idx_base + d_idxoff) << 2;
                    rd_req_len   <= idx_beats[7:0] - 8'd1;
                    rd_req_valid <= 1'b1;
                    state        <= C_IDX_DATA;
                end
            end

            C_IDX_DATA: begin
                if (rd_d_valid) begin
                    for (k = 0; k < LANES; k = k + 1)
                        if (idx_w + k < MAX_BAG)
                            idxbuf[idx_w + k] <= rd_d_data[32*k +: 32];
                    idx_w <= idx_w + LANES;
                    if (rd_d_last) state <= C_ROW;
                end
            end

            // ------------------------------------- classify + gather rows
            C_ROW: begin
                if (j == d_num) begin
                    state <= C_FLUSH;
                end else begin
                    ev_idx <= 1'b1;
                    if (cur_ix >= tab_rows) begin
                        err_index  <= 1'b1;
                        ev_invalid <= 1'b1;
                        j          <= j + 1'b1;
                    end else if (cur_ix < shard_lo || cur_ix >= shard_hi) begin
                        ev_remote <= 1'b1;
                        j         <= j + 1'b1;
                    end else if (ac_f_avail && rd_req_ready && !rd_req_valid) begin
                        // classify and issue in the same cycle, so back-to-back
                        // row bursts are separated by two cycles, not four
                        rd_req_addr  <= (tab_base + (cur_ix - shard_lo) * DIM) << 2;
                        rd_req_len   <= CHUNKS - 1;
                        rd_req_valid <= 1'b1;
                        ac_f_first   <= (cnt == 32'd0);
                        ev_local     <= 1'b1;
                        cnt          <= cnt + 1'b1;
                        j            <= j + 1'b1;
                        state        <= C_ROW_DATA;
                    end else begin
                        state <= C_ROW_REQ;
                    end
                end
            end

            C_ROW_REQ: begin
                // no staging buffer free yet (or the bus master is still busy);
                // in single-buffer mode this is where the fold of the previous
                // row is waited out, which is the cost the A/B run measures
                if (ac_f_avail && rd_req_ready && !rd_req_valid) begin
                    rd_req_addr  <= (tab_base + (cur_ix - shard_lo) * DIM) << 2;
                    rd_req_len   <= CHUNKS - 1;
                    rd_req_valid <= 1'b1;
                    ac_f_first   <= (cnt == 32'd0);
                    ev_local     <= 1'b1;
                    cnt          <= cnt + 1'b1;
                    j            <= j + 1'b1;
                    state        <= C_ROW_DATA;
                end
            end

            C_ROW_DATA: begin
                if (rd_d_valid && rd_d_last) state <= C_ROW;
            end

            // ------------------------------------------------ drain + write
            C_FLUSH: begin
                if (!ac_busy) state <= C_DRAIN;
            end

            C_DRAIN: begin
                if (wr_req_ready && !wr_req_valid) begin
                    wr_req_addr  <= (out_base + d_dstoff) << 2;
                    wr_req_len   <= CHUNKS - 1;
                    wr_req_valid <= 1'b1;
                    ac_d_start   <= 1'b1;
                    ac_d_count   <= cnt;
                    state        <= C_DRAIN_W;
                end
            end

            C_DRAIN_W: begin
                if (wr_done) state <= C_NEXT;
            end

            C_NEXT: begin
                if (desc_i + 1 == desc_count) state  <= C_FIN;
                else begin
                    desc_i <= desc_i + 1'b1;
                    state  <= C_DESC_REQ;
                end
            end

            // ------------------------------------------------------- abort
            C_ABORT: begin
                abort_wd <= abort_wd + 32'd1;
                if ((!rd_busy && !wr_busy) || abort_wd >= WDOG)
                    state <= C_FIN;
            end

            C_FIN: begin
                busy  <= 1'b0;
                fin   <= 1'b1;
                state <= C_IDLE;
            end

            default: state <= C_IDLE;
            endcase
            end
        end
    end
endmodule
