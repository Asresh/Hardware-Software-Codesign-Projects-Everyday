// ============================================================================
// emb_regfile - MMIO control / status plane.
//
// A flat 32-bit register window the host writes to place the descriptor ring,
// the index arena, the local table shard and the output region in device memory,
// to declare which slice of the global embedding table this device owns, and to
// start the walk.  On the way back it exposes the pooling statistics the runtime
// needs - how many indices landed locally versus on a peer shard, how many
// memory beats each direction cost, and how long the run took - plus a sticky
// done / error interrupt cleared by writing 1 to the flag.
//
// The remote-index count is the interesting one: it is exactly the number of
// embedding rows this device did *not* have, which is what a sharded recommender
// needs in order to size the all-to-all that follows.
// ============================================================================
`include "emb_defs.vh"

module emb_regfile #(
    parameter LANES  = `EMB_LANES,
    parameter CHUNKS = `EMB_DIM / `EMB_LANES
) (
    input  wire        clk,
    input  wire        rst,

    // ---- MMIO slave -----------------------------------------------------
    input  wire        reg_sel,
    input  wire        reg_we,
    input  wire [7:0]  reg_addr,
    input  wire [31:0] reg_wdata,
    output reg  [31:0] reg_rdata,

    // ---- to the core ----------------------------------------------------
    output reg         start,
    output reg         single_buf,
    output reg  [31:0] desc_base,
    output reg  [31:0] desc_count,
    output reg  [31:0] idx_base,
    output reg  [31:0] tab_base,
    output reg  [31:0] out_base,
    output reg  [31:0] shard_lo,
    output reg  [31:0] shard_hi,
    output reg  [31:0] tab_rows,

    // ---- from the core / masters ----------------------------------------
    input  wire        core_busy,
    input  wire        core_fin,
    input  wire        err_baglen,
    input  wire        err_index,
    input  wire        err_bus,
    input  wire        ev_desc,
    input  wire        ev_idx,
    input  wire        ev_local,
    input  wire        ev_remote,
    input  wire        ev_invalid,
    input  wire        ev_rbeat,
    input  wire        ev_wbeat,

    output wire        irq
);
    reg        irq_en;
    reg        st_done;
    reg [31:0] c_desc, c_idx, c_local, c_remote, c_invalid;
    reg [31:0] c_rbeat, c_wbeat, c_cycles;
    reg        irq_done, irq_err;

    wire wr = reg_sel & reg_we;
    wire rd = reg_sel & ~reg_we;

    wire [31:0] status = {27'd0, err_bus, err_index, err_baglen, st_done, core_busy};
    wire [31:0] id_reg = 32'hE9B00000 | (CHUNKS << 8) | LANES;

    assign irq = irq_en & (irq_done | irq_err);

    always @(posedge clk) begin
        if (rst) begin
            start      <= 1'b0;
            single_buf <= 1'b0;
            irq_en     <= 1'b0;
            desc_base  <= 32'd0;
            desc_count <= 32'd0;
            idx_base   <= 32'd0;
            tab_base   <= 32'd0;
            out_base   <= 32'd0;
            shard_lo   <= 32'd0;
            shard_hi   <= 32'd0;
            tab_rows   <= 32'd0;
            st_done    <= 1'b0;
            c_desc     <= 32'd0;
            c_idx      <= 32'd0;
            c_local    <= 32'd0;
            c_remote   <= 32'd0;
            c_invalid  <= 32'd0;
            c_rbeat    <= 32'd0;
            c_wbeat    <= 32'd0;
            c_cycles   <= 32'd0;
            irq_done   <= 1'b0;
            irq_err    <= 1'b0;
        end else begin
            start <= 1'b0;

            // ---------------------------------------------------- writes
            if (wr) begin
                case (reg_addr)
                `EMB_REG_CTRL: begin
                    single_buf <= reg_wdata[1];
                    irq_en     <= reg_wdata[2];
                    if (reg_wdata[3]) begin
                        c_desc    <= 32'd0;
                        c_idx     <= 32'd0;
                        c_local   <= 32'd0;
                        c_remote  <= 32'd0;
                        c_invalid <= 32'd0;
                        c_rbeat   <= 32'd0;
                        c_wbeat   <= 32'd0;
                    end
                    if (reg_wdata[0] && !core_busy) begin
                        start    <= 1'b1;
                        st_done  <= 1'b0;
                        c_cycles <= 32'd0;
                    end
                end
                `EMB_REG_IRQ: begin
                    if (reg_wdata[0]) irq_done <= 1'b0;
                    if (reg_wdata[1]) irq_err  <= 1'b0;
                end
                `EMB_REG_DESC_BASE:  desc_base  <= reg_wdata;
                `EMB_REG_DESC_COUNT: desc_count <= reg_wdata;
                `EMB_REG_IDX_BASE:   idx_base   <= reg_wdata;
                `EMB_REG_TAB_BASE:   tab_base   <= reg_wdata;
                `EMB_REG_OUT_BASE:   out_base   <= reg_wdata;
                `EMB_REG_SHARD_LO:   shard_lo   <= reg_wdata;
                `EMB_REG_SHARD_HI:   shard_hi   <= reg_wdata;
                `EMB_REG_TAB_ROWS:   tab_rows   <= reg_wdata;
                default: ;
                endcase
            end

            // ------------------------------------------------- statistics
            if (core_busy) c_cycles <= c_cycles + 32'd1;
            if (ev_desc)    c_desc    <= c_desc    + 32'd1;
            if (ev_idx)     c_idx     <= c_idx     + 32'd1;
            if (ev_local)   c_local   <= c_local   + 32'd1;
            if (ev_remote)  c_remote  <= c_remote  + 32'd1;
            if (ev_invalid) c_invalid <= c_invalid + 32'd1;
            if (ev_rbeat)   c_rbeat   <= c_rbeat   + 32'd1;
            if (ev_wbeat)   c_wbeat   <= c_wbeat   + 32'd1;

            // ------------------------------------------------- completion
            if (core_fin) begin
                st_done  <= 1'b1;
                irq_done <= 1'b1;
                if (err_baglen | err_index | err_bus) irq_err <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------- reads
    always @(posedge clk) begin
        if (rst) begin
            reg_rdata <= 32'd0;
        end else if (rd) begin
            case (reg_addr)
            `EMB_REG_CTRL:       reg_rdata <= {29'd0, irq_en, single_buf, 1'b0};
            `EMB_REG_STATUS:     reg_rdata <= status;
            `EMB_REG_IRQ:        reg_rdata <= {30'd0, irq_err, irq_done};
            `EMB_REG_DESC_BASE:  reg_rdata <= desc_base;
            `EMB_REG_DESC_COUNT: reg_rdata <= desc_count;
            `EMB_REG_IDX_BASE:   reg_rdata <= idx_base;
            `EMB_REG_TAB_BASE:   reg_rdata <= tab_base;
            `EMB_REG_OUT_BASE:   reg_rdata <= out_base;
            `EMB_REG_SHARD_LO:   reg_rdata <= shard_lo;
            `EMB_REG_SHARD_HI:   reg_rdata <= shard_hi;
            `EMB_REG_TAB_ROWS:   reg_rdata <= tab_rows;
            `EMB_REG_ST_DESC:    reg_rdata <= c_desc;
            `EMB_REG_ST_IDX:     reg_rdata <= c_idx;
            `EMB_REG_ST_LOCAL:   reg_rdata <= c_local;
            `EMB_REG_ST_REMOTE:  reg_rdata <= c_remote;
            `EMB_REG_ST_INVALID: reg_rdata <= c_invalid;
            `EMB_REG_ST_RBEATS:  reg_rdata <= c_rbeat;
            `EMB_REG_ST_WBEATS:  reg_rdata <= c_wbeat;
            `EMB_REG_ST_CYCLES:  reg_rdata <= c_cycles;
            `EMB_REG_ID:         reg_rdata <= id_reg;
            default:             reg_rdata <= 32'd0;
            endcase
        end
    end
endmodule
