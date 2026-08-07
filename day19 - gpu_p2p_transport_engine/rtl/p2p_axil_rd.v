// ============================================================================
// p2p_axil_rd - pipelined AXI4-Lite read master.
//
// AR runs ahead of R by up to OUTSTANDING addresses, so a memory that answers
// one word per clock is kept at one word per clock even though its latency is
// several cycles. AXI4-Lite returns reads in order on a single ID, so no
// reorder buffer is needed: whoever asked first is answered first, and the
// arbiter above only has to remember the *order* of the requesters, not tag
// every transaction.
//
// rready is tied high. That is a contract with the requesters, not laziness:
// each of them reserves a landing slot before it is allowed to issue, so a
// returning word can never have to wait, and one requester can never back up
// the shared read channel and stall the other direction of the link.
// ============================================================================
`timescale 1ns/1ps

module p2p_axil_rd #(
    parameter OUTSTANDING = 4
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- internal request / response ---------------------------------------
    input  wire        req_valid,
    input  wire [31:0] req_addr,
    output wire        req_ready,

    output wire        rsp_valid,
    output wire [31:0] rsp_data,
    output wire        rsp_err,

    output wire [3:0]  outstanding,

    // ---- AXI4-Lite read ----------------------------------------------------
    output wire [31:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output wire        m_rready
);

    reg [3:0] cnt;

    wire room  = (cnt < OUTSTANDING[3:0]);

    assign m_araddr  = req_addr;
    assign m_arvalid = req_valid && room;
    assign req_ready = m_arready && room;

    assign m_rready  = 1'b1;
    assign rsp_valid = m_rvalid;
    assign rsp_data  = m_rdata;
    assign rsp_err   = m_rvalid && (m_rresp != 2'b00);

    assign outstanding = cnt;

    wire issue = m_arvalid && m_arready;
    wire retire = m_rvalid && m_rready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                 cnt <= 4'd0;
        else case ({issue, retire})
            2'b10:   cnt <= cnt + 4'd1;
            2'b01:   cnt <= cnt - 4'd1;
            default: cnt <= cnt;
        endcase
    end

endmodule
