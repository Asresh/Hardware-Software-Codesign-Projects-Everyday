// ann_reg.vh - MMIO register map, mirrored from sw/ann.h (single source of
// truth for the software/hardware contract).  Word index = byte address >> 2.
localparam [7:0] REG_CTRL       = 8'd0;
localparam [7:0] REG_STATUS     = 8'd1;
localparam [7:0] REG_NDB        = 8'd2;
localparam [7:0] REG_IRQ_ACK    = 8'd3;
localparam [7:0] REG_VERSION    = 8'd4;
localparam [7:0] REG_STAT_VECS  = 8'd5;
localparam [7:0] REG_STAT_BEATS = 8'd6;
localparam [7:0] REG_LAST_CYC   = 8'd7;
localparam [7:0] REG_ERRCODE    = 8'd8;
localparam [7:0] REG_QUERY_BASE = 8'd32;
localparam [7:0] REG_SCORE_BASE = 8'd128;
localparam [7:0] REG_ID_BASE    = 8'd192;

localparam [31:0] ANN_VERSION = 32'h0015_0001;
localparam [3:0]  ERR_TRUNC   = 4'd1;
