// ===========================================================================
// mxq_defs.vh - Verilog mirror of sw/mxq.h.
//
// Everything the hardware and the software both have to agree on lives here
// and in sw/mxq.h, and nowhere else.  MXQ_REGMAP_CSUM is the fold of the
// register offsets; the host recomputes it from its own header and the
// testbench reads it out of MXQ_REG_REGMAP_CSUM, so the two files cannot
// drift apart without the run failing.
// ===========================================================================
`ifndef MXQ_DEFS_VH
`define MXQ_DEFS_VH

`ifndef MXQ_IMEM_W
`define MXQ_IMEM_W 12
`endif
`ifndef MXQ_DMEM_W
`define MXQ_DMEM_W 12
`endif

// ---- register file: word index = byte offset >> 2 ------------------------
`define MXQ_R_CTRL         6'h00
`define MXQ_R_STATUS       6'h01
`define MXQ_R_IRQ_STAT     6'h02
`define MXQ_R_ERRCODE      6'h03
`define MXQ_R_START_PC     6'h04
`define MXQ_R_WDOG         6'h05
`define MXQ_R_CYCLES       6'h06
`define MXQ_R_INSTRET      6'h07
`define MXQ_R_CUSTOM_OPS   6'h08
`define MXQ_R_BRANCH_TAKEN 6'h09
`define MXQ_R_LOADS        6'h0A
`define MXQ_R_STORES       6'h0B
`define MXQ_R_TRAP_PC      6'h0C
`define MXQ_R_ARG0         6'h0D
`define MXQ_R_ARG1         6'h0E
`define MXQ_R_ARG2         6'h0F
`define MXQ_R_ARG3         6'h10
`define MXQ_R_RETVAL       6'h11
`define MXQ_R_HALT_PC      6'h12
`define MXQ_R_CAPS         6'h13
`define MXQ_R_VERSION      6'h14
`define MXQ_R_REGMAP_CSUM  6'h15

`define MXQ_NREGS      22
`define MXQ_NCUSTOM    5
`define MXQ_REGMAP_CSUM 32'h0001_985A
`define MXQ_VERSION_ID  32'h0015_0001

// window decode on the host address bus
`define MXQ_WIN_IMEM 4'h1      // addr[19:16]
`define MXQ_WIN_DMEM 4'h2
`define MXQ_WIN_REGS 4'h0

// ---- CTRL / STATUS / IRQ --------------------------------------------------
`define MXQ_CTRL_START    0
`define MXQ_CTRL_IRQ_EN   1
`define MXQ_CTRL_SOFT_RST 2
`define MXQ_CTRL_CLR_STAT 3

`define MXQ_ST_RUNNING 0
`define MXQ_ST_HALTED  1
`define MXQ_ST_TRAP    2

`define MXQ_IRQ_DONE 0
`define MXQ_IRQ_TRAP 1

// ---- trap causes ----------------------------------------------------------
`define MXQ_ERR_NONE        4'd0
`define MXQ_ERR_ILLEGAL     4'd1
`define MXQ_ERR_LOAD_ALIGN  4'd2
`define MXQ_ERR_STORE_ALIGN 4'd3
`define MXQ_ERR_LOAD_FAULT  4'd4
`define MXQ_ERR_STORE_FAULT 4'd5
`define MXQ_ERR_FETCH_FAULT 4'd6
`define MXQ_ERR_WDOG        4'd7

// ---- opcodes --------------------------------------------------------------
`define MXQ_OP_LOAD   7'h03
`define MXQ_OP_OPIMM  7'h13
`define MXQ_OP_AUIPC  7'h17
`define MXQ_OP_STORE  7'h23
`define MXQ_OP_OP     7'h33
`define MXQ_OP_LUI    7'h37
`define MXQ_OP_BRANCH 7'h63
`define MXQ_OP_JALR   7'h67
`define MXQ_OP_JAL    7'h6F
`define MXQ_OP_SYSTEM 7'h73
`define MXQ_OP_CUSTOM 7'h0B

`define MXQ_F3_AMAX  3'd0
`define MXQ_F3_SCALE 3'd1
`define MXQ_F3_Q4    3'd2
`define MXQ_F3_DQ    3'd3
`define MXQ_F3_PK    3'd4

// ---- MX numeric format ----------------------------------------------------
`define MXQ_EMAX_ELEM 8'd2
`define MXQ_BF16_MAXF 15'h7F7F

`endif
