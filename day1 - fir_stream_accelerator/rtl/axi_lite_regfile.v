// -----------------------------------------------------------------------------
// axi_lite_regfile.v
// AXI4-Lite slave that forms the control plane of the FIR accelerator. It is a
// single-outstanding, always-OKAY slave (the standard lightweight profile used
// for a CSR block). All five AXI channels use the canonical valid/ready
// handshake; byte strobes (WSTRB) are honored on register writes.
//
// Register map (byte offsets, 32-bit registers):
//   0x00 CTRL     WO*  bit0 START (self-clearing), bit1 IRQ_EN, bit2 SOFT_CLR
//   0x04 STATUS   RO   bit0 DONE, bit1 BUSY  (DONE is set by the core and
//                      cleared automatically on the next START)
//   0x08 LENGTH   RW   number of samples in the job
//   0x0C TAP_COUNT   RO   compile-time TAPS
//   0x10 DATA_WIDTH  RO   compile-time DATA_WIDTH
//   0x14 SAMPLES_OUT RO   results produced in the current/last job
//   0x18 IN_LEVEL    RO   input FIFO occupancy
//   0x1C OUT_LEVEL   RO   output FIFO occupancy
//   0x40 + 4*i COEF[i]  RW   signed coefficient i, i in [0, TAPS-1]
//   (*) CTRL reads back IRQ_EN in bit1; START/SOFT_CLR read as 0.
// -----------------------------------------------------------------------------
`default_nettype none

module axi_lite_regfile #(
    parameter integer TAPS       = 8,
    parameter integer COEF_WIDTH = 16,     // <= 32
    parameter integer DATA_WIDTH = 16,     // reported via the DATA_WIDTH CSR
    parameter integer LEN_WIDTH  = 16,
    parameter integer ADDR_WIDTH = 8       // byte address width of the CSR space
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // ---- AXI4-Lite slave ----
    input  wire [ADDR_WIDTH-1:0]       s_awaddr,
    input  wire                        s_awvalid,
    output reg                         s_awready,
    input  wire [31:0]                 s_wdata,
    input  wire [3:0]                  s_wstrb,
    input  wire                        s_wvalid,
    output reg                         s_wready,
    output reg  [1:0]                  s_bresp,
    output reg                         s_bvalid,
    input  wire                        s_bready,
    input  wire [ADDR_WIDTH-1:0]       s_araddr,
    input  wire                        s_arvalid,
    output reg                         s_arready,
    output reg  [31:0]                 s_rdata,
    output reg  [1:0]                  s_rresp,
    output reg                         s_rvalid,
    input  wire                        s_rready,

    // ---- decoded control outputs to the core ----
    output wire [TAPS*COEF_WIDTH-1:0]  coef_flat,
    output wire [LEN_WIDTH-1:0]        length,
    output reg                         start_pulse,
    output reg                         clr_pulse,
    output reg                         irq_en,

    // ---- status inputs from the core ----
    input  wire                        done,
    input  wire                        busy,
    input  wire [31:0]                 samples_out,
    input  wire [31:0]                 in_level,
    input  wire [31:0]                 out_level
);
    localparam [1:0] RESP_OKAY = 2'b00;
    localparam integer WA = ADDR_WIDTH - 2;      // word-address width

    // ---------------- register storage ----------------
    reg [COEF_WIDTH-1:0] coef_reg [0:TAPS-1];
    reg [LEN_WIDTH-1:0]  length_reg;

    genvar gi;
    generate
        for (gi = 0; gi < TAPS; gi = gi + 1) begin : g_pack
            assign coef_flat[gi*COEF_WIDTH +: COEF_WIDTH] = coef_reg[gi];
        end
    endgenerate
    assign length = length_reg;

    // ---------------- write channel (single outstanding) ----------------
    // Xilinx-style template: awready/wready pulse for one cycle when both
    // address and data are present and no write response is pending.
    reg [ADDR_WIDTH-1:0] waddr_q;
    wire wr_fire = s_awready & s_awvalid & s_wready & s_wvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_awready <= 1'b0;
            s_wready  <= 1'b0;
            waddr_q   <= {ADDR_WIDTH{1'b0}};
        end else begin
            if (!s_awready && s_awvalid && s_wvalid && !s_bvalid) begin
                s_awready <= 1'b1;
                s_wready  <= 1'b1;
                waddr_q   <= s_awaddr;
            end else begin
                s_awready <= 1'b0;
                s_wready  <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            s_bvalid <= 1'b0;
            s_bresp  <= RESP_OKAY;
        end else begin
            if (wr_fire) begin
                s_bvalid <= 1'b1;
                s_bresp  <= RESP_OKAY;
            end else if (s_bvalid && s_bready) begin
                s_bvalid <= 1'b0;
            end
        end
    end

    // byte-strobed write helper
    function [31:0] apply_strb;
        input [31:0] oldv;
        input [31:0] neww;
        input [3:0]  strb;
        integer b;
        begin
            apply_strb = oldv;
            for (b = 0; b < 4; b = b + 1)
                if (strb[b]) apply_strb[b*8 +: 8] = neww[b*8 +: 8];
        end
    endfunction

    wire [WA-1:0] w_word = waddr_q[ADDR_WIDTH-1:2];
    integer ci;

    always @(posedge clk) begin
        if (!rst_n) begin
            length_reg  <= {LEN_WIDTH{1'b0}};
            irq_en      <= 1'b0;
            start_pulse <= 1'b0;
            clr_pulse   <= 1'b0;
            for (ci = 0; ci < TAPS; ci = ci + 1)
                coef_reg[ci] <= {COEF_WIDTH{1'b0}};
        end else begin
            // control pulses are one cycle wide
            start_pulse <= 1'b0;
            clr_pulse   <= 1'b0;
            if (wr_fire) begin
                case (w_word)
                    6'h00: begin                       // CTRL @ 0x00
                        if (s_wstrb[0]) begin
                            start_pulse <= s_wdata[0];
                            irq_en      <= s_wdata[1];
                            clr_pulse   <= s_wdata[2];
                        end
                    end
                    6'h02: begin                       // LENGTH @ 0x08
                        length_reg <= apply_strb({{(32-LEN_WIDTH){1'b0}}, length_reg},
                                                 s_wdata, s_wstrb);
                    end
                    default: begin
                        // COEF window: 0x40..(0x40+4*TAPS-4) -> words 16..16+TAPS-1
                        if (w_word >= 6'h10 && w_word < (6'h10 + TAPS[WA-1:0])) begin
                            coef_reg[w_word - 6'h10] <=
                                apply_strb({{(32-COEF_WIDTH){1'b0}}, coef_reg[w_word - 6'h10]},
                                           s_wdata, s_wstrb);
                        end
                    end
                endcase
            end
        end
    end

    // ---------------- read channel (single outstanding) ----------------
    reg [ADDR_WIDTH-1:0] raddr_q;
    wire [WA-1:0] r_word = raddr_q[ADDR_WIDTH-1:2];

    always @(posedge clk) begin
        if (!rst_n) begin
            s_arready <= 1'b0;
            raddr_q   <= {ADDR_WIDTH{1'b0}};
        end else begin
            if (!s_arready && s_arvalid && !s_rvalid) begin
                s_arready <= 1'b1;
                raddr_q   <= s_araddr;
            end else begin
                s_arready <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            s_rvalid <= 1'b0;
            s_rresp  <= RESP_OKAY;
            s_rdata  <= 32'h0;
        end else begin
            if (s_arready && s_arvalid) begin
                s_rvalid <= 1'b1;
                s_rresp  <= RESP_OKAY;
                case (r_word)
                    6'h00: s_rdata <= {30'h0, irq_en, 1'b0};                 // CTRL
                    6'h01: s_rdata <= {29'h0, 1'b0, busy, done};             // STATUS
                    6'h02: s_rdata <= {{(32-LEN_WIDTH){1'b0}}, length_reg};  // LENGTH
                    6'h03: s_rdata <= TAPS[31:0];                            // TAP_COUNT
                    6'h04: s_rdata <= DATA_WIDTH[31:0];                      // DATA_WIDTH
                    6'h05: s_rdata <= samples_out;                          // SAMPLES_OUT
                    6'h06: s_rdata <= in_level;                             // IN_LEVEL
                    6'h07: s_rdata <= out_level;                            // OUT_LEVEL
                    default: begin
                        if (r_word >= 6'h10 && r_word < (6'h10 + TAPS[WA-1:0]))
                            s_rdata <= {{(32-COEF_WIDTH){coef_reg[r_word - 6'h10][COEF_WIDTH-1]}},
                                        coef_reg[r_word - 6'h10]};
                        else
                            s_rdata <= 32'hDEAD_BEEF;
                    end
                endcase
            end else if (s_rvalid && s_rready) begin
                s_rvalid <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
