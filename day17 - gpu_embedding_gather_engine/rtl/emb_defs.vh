// emb_defs.vh - shared parameters and encodings for the embedding gather engine.
// Overridable from the Makefile (-DEMB_DIM=... etc.) so that the RTL, the golden
// model and the testbench are all built from one set of numbers.
`ifndef EMB_DEFS_VH
`define EMB_DEFS_VH

`ifndef EMB_DIM
  `define EMB_DIM 64
`endif
`ifndef EMB_LANES
  `define EMB_LANES 4
`endif
`ifndef EMB_MAX_BAG
  `define EMB_MAX_BAG 64
`endif

// pooling opcodes (descriptor word 0, bits [1:0])
`define EMB_OP_SUM  2'd0
`define EMB_OP_MEAN 2'd1
`define EMB_OP_MAX  2'd2
`define EMB_OP_MIN  2'd3

// descriptor geometry: 8 words / 32 bytes, beat-aligned for LANES in {2,4,8}
`define EMB_DESC_WORDS 8

// MMIO register offsets (byte address, word-aligned)
`define EMB_REG_CTRL       8'h00
`define EMB_REG_STATUS     8'h04
`define EMB_REG_IRQ        8'h08
`define EMB_REG_DESC_BASE  8'h0C
`define EMB_REG_DESC_COUNT 8'h10
`define EMB_REG_IDX_BASE   8'h14
`define EMB_REG_TAB_BASE   8'h18
`define EMB_REG_OUT_BASE   8'h1C
`define EMB_REG_SHARD_LO   8'h20
`define EMB_REG_SHARD_HI   8'h24
`define EMB_REG_TAB_ROWS   8'h28
`define EMB_REG_ST_DESC    8'h2C
`define EMB_REG_ST_IDX     8'h30
`define EMB_REG_ST_LOCAL   8'h34
`define EMB_REG_ST_REMOTE  8'h38
`define EMB_REG_ST_INVALID 8'h3C
`define EMB_REG_ST_RBEATS  8'h40
`define EMB_REG_ST_WBEATS  8'h44
`define EMB_REG_ST_CYCLES  8'h48
`define EMB_REG_ID         8'h4C

// bus watchdog: cycles a single outstanding transaction may take before the
// engine declares a bus error and aborts instead of hanging the ring walk
`ifndef EMB_WDOG
  `define EMB_WDOG 1024
`endif

`endif
