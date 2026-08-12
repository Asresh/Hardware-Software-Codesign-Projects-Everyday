// ===========================================================================
// sdv_defs.vh - shared parameters, register map and encodings.
//               Verilog mirror of sw/sdv.h; REG_REGMAP_CSUM is read back in
//               simulation and compared against the C constant, so the two
//               files cannot drift apart without the testbench noticing.
// ===========================================================================
`ifndef SDV_DEFS_VH
`define SDV_DEFS_VH

`ifndef SDV_MAX_NODES
 `define SDV_MAX_NODES 64
`endif
`ifndef SDV_MAX_DEPTH
 `define SDV_MAX_DEPTH 16
`endif

`define SDV_ROOT_PARENT 16'hFFFF

// acceptance modes (CTRL[3:2])
`define SDV_MODE_GREEDY  2'd0
`define SDV_MODE_TYPICAL 2'd1
`define SDV_MODE_BOTH    2'd2
`define SDV_MODE_ANY     2'd3

// error codes, in detection priority order
`define SDV_ERR_NONE   3'd0
`define SDV_ERR_NNODES 3'd1
`define SDV_ERR_ROOT   3'd2
`define SDV_ERR_PARENT 3'd3
`define SDV_ERR_SELF   3'd4

`define SDV_FLAG_CLAMP 16'h0001

// register map, as word indices (APB byte address >> 2)
`define R_CTRL        8'h00
`define R_STATUS      8'h01
`define R_TH_ABS      8'h02
`define R_TH_REL      8'h03
`define R_MAX_ACC     8'h04
`define R_IRQ_STAT    8'h05
`define R_ERRCODE     8'h06
`define R_CAPS        8'h07
`define R_VERSION     8'h08
`define R_ST_JOBS     8'h09
`define R_ST_NODES    8'h0A
`define R_ST_ACCEPT   8'h0B
`define R_ST_ERRJOBS  8'h0C
`define R_ST_CLAMP    8'h0D
`define R_ST_BUSY     8'h0E
`define R_ST_SRCSTALL 8'h0F
`define R_ST_BPSTALL  8'h10
`define R_ST_LASTCYC  8'h11
`define R_ST_LASTACC  8'h12
`define R_REGMAP_CSUM 8'h13
`define R_HIST_BASE   8'h20

`define SDV_VERSION     32'h0020_0001
`define SDV_REGMAP_CSUM 32'h0000_3410

`define SDV_IRQ_DONE  3'b001
`define SDV_IRQ_ERROR 3'b010
`define SDV_IRQ_CLAMP 3'b100

`endif
