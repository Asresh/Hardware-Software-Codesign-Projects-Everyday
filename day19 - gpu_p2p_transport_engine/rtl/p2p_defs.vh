// ============================================================================
// p2p_defs.vh - shared encodings for the GPU-to-GPU peer transport engine.
//
// Everything in here is duplicated, value for value, in sw/p2p.h so that the
// firmware, the golden model and the RTL cannot drift apart.
// ============================================================================
`ifndef P2P_DEFS_VH
`define P2P_DEFS_VH

// ---- control-plane register offsets (byte address, AXI4-Lite, 32-bit) ------
`define P2P_CTRL        8'h00   // [0] START (self-clearing)  [1] CLEAR_STATS
`define P2P_STATUS      8'h04   // [0] BUSY [1] DONE [2] ERR [3] SEQERR
`define P2P_WQ_BASE     8'h08   // byte address of the work-queue ring
`define P2P_WQ_COUNT    8'h0C   // number of work-queue entries to consume
`define P2P_CQ_BASE     8'h10   // byte address of the completion-queue ring
`define P2P_MEM_LIMIT   8'h14   // byte size of the addressable window
`define P2P_CREDIT_LIM  8'h18   // usable link credits, 1 .. RX_BUFS
`define P2P_INJECT      8'h1C   // [0] skip one sequence number in this run
`define P2P_IRQ_EN      8'h20   // [0] done  [1] error
`define P2P_IRQ_STAT    8'h24   // write-1-to-clear
`define P2P_ERR_CODE    8'h28   // first error code latched this run
`define P2P_ERR_INFO    8'h2C   // work-queue index that raised it
`define P2P_ST_WQE      8'h30   // work-queue entries accepted
`define P2P_ST_PKT      8'h34   // packets transmitted
`define P2P_ST_TXW      8'h38   // payload words transmitted
`define P2P_ST_RXW      8'h3C   // payload words committed to memory
`define P2P_ST_CQE      8'h40   // completion entries posted
`define P2P_ST_ERR      8'h44   // rejected work-queue entries
`define P2P_ST_SEQ      8'h48   // packets dropped on a sequence mismatch
`define P2P_ST_CYCLES   8'h4C   // cycles from START to DONE
`define P2P_ST_CRSTALL  8'h50   // cycles the transmitter waited on a credit
`define P2P_ST_LKSTALL  8'h54   // cycles the transmitter waited on the link
`define P2P_ST_MEMSTALL 8'h58   // cycles a datapath waited on the memory port
`define P2P_CAPS        8'h5C   // {RX_BUFS, NUM_QP, MTU_WORDS} packed

// ---- work-queue entry, 8 words (32 bytes) ---------------------------------
//   w0 : [3:0] opcode, [7:4] queue pair, [31:8] reserved
//   w1 : source byte address       (local, 4-byte aligned)
//   w2 : destination byte address  (peer,  4-byte aligned)
//   w3 : length in 32-bit words
//   w4 : message tag echoed into the completion entry
//   w5 : reserved
//   w6 : reserved
//   w7 : reserved
`define P2P_WQE_WORDS   8

// ---- completion entry, 4 words (16 bytes) ---------------------------------
//   w0 : [7:0] status, [11:8] queue pair, [15:12] opcode
//   w1 : message tag
//   w2 : bytes committed
//   w3 : sequence number of the last packet of the message
`define P2P_CQE_WORDS   4

// ---- opcodes ---------------------------------------------------------------
`define P2P_OP_WRITE    4'd0    // overwrite the destination words
`define P2P_OP_ACCUM    4'd1    // destination += payload, 32-bit wrapping add

// ---- error codes -----------------------------------------------------------
`define P2P_ERR_NONE    4'd0
`define P2P_ERR_OP      4'd1    // unknown opcode
`define P2P_ERR_QP      4'd2    // queue pair out of range
`define P2P_ERR_LEN     4'd3    // length over MAX_MSG_WORDS
`define P2P_ERR_ALIGN   4'd4    // source or destination not word aligned
`define P2P_ERR_RANGE   4'd5    // region crosses MEM_LIMIT
`define P2P_ERR_BUS     4'd6    // SLVERR on the memory port

// ---- link header -----------------------------------------------------------
//   beat 0 : [7:0] payload words, [11:8] qp, [15:12] flags, [23:16] seq,
//            [31:24] message tag                      (tuser = 1 on this beat)
//   beat 1 : destination byte address of this packet  (tlast if len == 0)
`define P2P_FLAG_FIRST  4'h1
`define P2P_FLAG_LAST   4'h2
`define P2P_FLAG_ACCUM  4'h4

`endif
