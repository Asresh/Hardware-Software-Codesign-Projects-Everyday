// ============================================================================
// kvp_defs.vh - shared encodings for the KV-cache paging engine.
//   Kept byte-identical with sw/kvp.h (register indices, opcodes, result flags)
//   so firmware, golden model and RTL cannot drift apart.
// ============================================================================

// ---- MMIO register indices (byte address = index*4) ----
localparam [7:0] R_CTRL        = 8'd0,
                 R_STATUS      = 8'd1,
                 R_REQ_BASE    = 8'd2,
                 R_RES_BASE    = 8'd3,
                 R_REQ_COUNT   = 8'd4,
                 R_BT_BASE     = 8'd5,
                 R_BT_STRIDE   = 8'd6,
                 R_FREE_PUSH   = 8'd7,
                 R_FREE_COUNT  = 8'd8,
                 R_STAT_REQS   = 8'd9,
                 R_STAT_XLATES = 8'd10,
                 R_STAT_HITS   = 8'd11,
                 R_STAT_MISSES = 8'd12,
                 R_STAT_ALLOCS = 8'd13,
                 R_STAT_FREES  = 8'd14,
                 R_STAT_ERRS   = 8'd15,
                 R_LAST_CYC    = 8'd16,
                 R_RES_WORDS   = 8'd17,
                 R_IRQ_ACK     = 8'd18,
                 R_VERSION     = 8'd19;

// ---- CTRL bits ----
localparam integer CTRL_START_B = 0;   // W1S, self-clearing: launch a batch
localparam integer CTRL_SRST_B  = 1;   // W1S, self-clearing: clear TLB/freelist/stats
localparam integer CTRL_IRQEN_B = 2;   // level: enable the interrupt output

// ---- STATUS bits ----
localparam integer ST_BUSY_B    = 0;
localparam integer ST_DONE_B    = 1;   // sticky, W1C via R_IRQ_ACK
localparam integer ST_OOM_B     = 2;   // sticky: free list ran dry
localparam integer ST_BUS_B     = 3;   // sticky: Wishbone ERR_I or master timeout
localparam integer ST_IRQ_B     = 4;

// ---- request opcodes: word = {op[3:0], seq[11:0], arg[15:0]} ----
localparam [3:0] OP_XLATE   = 4'd0,   // arg = logical block, allocate on invalid
                 OP_RANGE   = 4'd1,   // arg = count, translate logical 0..count-1
                 OP_NOALLOC = 4'd2,   // arg = logical block, error on invalid
                 OP_FREE    = 4'd3,   // arg = count, return blocks 0..count-1
                 OP_FLUSH   = 4'd4;   // invalidate the whole translation cache

// ---- result word = {flags[7:0], payload[23:0]} ----
localparam integer F_HIT_B     = 0;   // served from the translation cache
localparam integer F_ALLOC_B   = 1;   // a new physical block was allocated
localparam integer F_FREED_B   = 2;   // payload = number of blocks returned
localparam integer F_FLUSHED_B = 3;
localparam integer F_EINVAL_B  = 4;   // NOALLOC hit an invalid block-table entry
localparam integer F_EOOM_B    = 5;   // free list empty
localparam integer F_EBADOP_B  = 6;   // unknown opcode

localparam [31:0] BT_INVALID = 32'hFFFF_FFFF;
localparam [31:0] KVP_VERSION = 32'h0016_0001;
