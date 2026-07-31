// ============================================================================
// bpd_regfile.v  -  AXI4-Lite control / status register file
//
//  0x00 CTRL     RW  [0] EN  [1] IRQ_EN  [2] SOFT_RST(self-clearing pulse)
//  0x04 STATUS   RO  [0] BUSY [1] DONE(sticky) [2] ERR(sticky) [3] IRQ
//  0x08 BLOCKS   RO  blocks decoded
//  0x0C VALUES   RO  values emitted
//  0x10 CYCLES   RO  active decode cycles
//  0x14 ERRCODE  RO  last error code
//  0x18 IRQ_ACK  W1C write any value clears DONE/ERR/IRQ
//  0x1C ID       RO  0xB17DEC10
// ============================================================================
`default_nettype none

module bpd_regfile (
    input  wire        clk,
    input  wire        rst,

    // AXI4-Lite slave
    input  wire [7:0]  awaddr,
    input  wire        awvalid,
    output reg         awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wvalid,
    output reg         wready,
    output reg [1:0]   bresp,
    output reg         bvalid,
    input  wire        bready,
    input  wire [7:0]  araddr,
    input  wire        arvalid,
    output reg         arready,
    output reg [31:0]  rdata,
    output reg [1:0]   rresp,
    output reg         rvalid,
    input  wire        rready,

    // control out
    output wire        en,
    output wire        irq_en,
    output reg         soft_rst,   // 1-cycle pulse

    // status in
    input  wire        busy,
    input  wire        done_pulse,
    input  wire        err_pulse,
    input  wire [31:0] errcode_in,
    input  wire [31:0] blocks_in,
    input  wire [31:0] values_in,
    input  wire [31:0] cycles_in,

    output wire        irq
);
    localparam [31:0] ID_VALUE = 32'hB17DEC10;

    reg [31:0] ctrl_q;
    reg        done_q, err_q;
    reg [31:0] errcode_q;

    assign en     = ctrl_q[0];
    assign irq_en = ctrl_q[1];
    assign irq    = irq_en & (done_q | err_q);

    // ---- write channel ----
    wire do_write = awvalid & wvalid & ~bvalid;
    always @(posedge clk) begin
        if (rst) begin
            awready  <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; bresp <= 2'b00;
            ctrl_q   <= 32'b0; soft_rst <= 1'b0;
            done_q   <= 1'b0; err_q <= 1'b0; errcode_q <= 32'b0;
        end else begin
            soft_rst <= 1'b0;
            awready  <= do_write;
            wready   <= do_write;
            if (do_write) begin
                bvalid <= 1'b1; bresp <= 2'b00;
                case (awaddr[7:2])
                    6'h00: begin
                        ctrl_q   <= {wdata[31:3], 1'b0, wdata[1:0]};
                        soft_rst <= wdata[2];
                    end
                    6'h06: begin // IRQ_ACK (0x18)
                        done_q <= 1'b0; err_q <= 1'b0;
                    end
                    default: ; // RO
                endcase
            end else if (bvalid & bready) begin
                bvalid <= 1'b0;
            end

            // status latches (pulses from core); ack above wins on same cycle
            if (done_pulse) done_q <= 1'b1;
            if (err_pulse) begin
                err_q     <= 1'b1;
                errcode_q <= errcode_in;
            end
        end
    end

    // ---- read channel ----
    always @(posedge clk) begin
        if (rst) begin
            arready <= 1'b0; rvalid <= 1'b0; rresp <= 2'b00; rdata <= 32'b0;
        end else begin
            arready <= arvalid & ~rvalid;
            if (arvalid & ~rvalid) begin
                rvalid <= 1'b1; rresp <= 2'b00;
                case (araddr[7:2])
                    6'h00: rdata <= ctrl_q;
                    6'h01: rdata <= {28'b0, irq, err_q, done_q, busy};
                    6'h02: rdata <= blocks_in;
                    6'h03: rdata <= values_in;
                    6'h04: rdata <= cycles_in;
                    6'h05: rdata <= errcode_q;
                    6'h07: rdata <= ID_VALUE;
                    default: rdata <= 32'b0;
                endcase
            end else if (rvalid & rready) begin
                rvalid <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
