// ============================================================================
// kds_defs.vh - geometry defaults and the register map, shared by every module
//               and by the testbench. The C side has the same map in sw/kds.h.
// ============================================================================
`ifndef KDS_DEFS_VH
`define KDS_DEFS_VH

`ifndef KDS_MAX_NODES
 `define KDS_MAX_NODES 64
`endif
`ifndef KDS_DEVICES
 `define KDS_DEVICES 4
`endif

// ---- register offsets (byte addresses on the AXI4-Lite control slave) ------
`define KDS_A_CTRL         8'h00
`define KDS_A_STATUS       8'h04
`define KDS_A_NUM_NODES    8'h08
`define KDS_A_NODE_BASE    8'h0C
`define KDS_A_RSLT_BASE    8'h10
`define KDS_A_IRQ_STATUS   8'h14
`define KDS_A_IRQ_ENABLE   8'h18
`define KDS_A_MAKESPAN     8'h1C
`define KDS_A_DISPATCHED   8'h20
`define KDS_A_STALL        8'h24
`define KDS_A_DEPWAIT      8'h28
`define KDS_A_MAXCONC      8'h2C
`define KDS_A_SERIAL       8'h30
`define KDS_A_BUSCYC       8'h34
`define KDS_A_FETCHW       8'h38
`define KDS_A_WBW          8'h3C
`define KDS_A_DEVBUSY0     8'h40
`define KDS_A_CAPS         8'h60

// ---- error codes -----------------------------------------------------------
`define KDS_E_NONE   4'd0
`define KDS_E_LEN    4'd1
`define KDS_E_DUR    4'd2
`define KDS_E_DEV    4'd3
`define KDS_E_DEP    4'd4
`define KDS_E_CYCLE  4'd5
`define KDS_E_BUS    4'd6

// ---- FSM states ------------------------------------------------------------
`define KDS_S_IDLE   3'd0
`define KDS_S_FETCH  3'd1
`define KDS_S_CHECK  3'd2
`define KDS_S_RUN    3'd3
`define KDS_S_WB     3'd4
`define KDS_S_DONE   3'd5
`define KDS_S_ERROR  3'd6

`endif
