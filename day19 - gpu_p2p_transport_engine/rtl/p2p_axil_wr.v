// ============================================================================
// p2p_axil_wr - pipelined AXI4-Lite write master.
//
// AW and W are independent channels, so they are allowed to handshake in
// either order; a request only retires from the master's point of view once
// both have gone out, which is what the two sticky "sent" flags are for. With
// a memory that takes a beat per clock this issues one word per clock, and up
// to OUTSTANDING B responses may be in flight behind it.
//
// The write channel belongs to the receive path (payload commit and completion
// entries) and the read channel to the transmit path, so a full-duplex
// transfer moves one word in and one word out on every clock.
// ============================================================================
`timescale 1ns/1ps

module p2p_axil_wr #(
    parameter OUTSTANDING = 4
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req_valid,
    input  wire [31:0] req_addr,
    input  wire [31:0] req_data,
    output wire        req_ready,

    output wire        done_valid,
    output wire        done_err,
    output wire [3:0]  outstanding,

    output wire [31:0] m_awaddr,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready
);

    reg [3:0] cnt;
    reg       aw_sent, w_sent;

    wire room = (cnt < OUTSTANDING[3:0]);
    wire fire = req_valid && room;

    assign m_awaddr  = req_addr;
    assign m_awvalid = fire && !aw_sent;
    assign m_wdata   = req_data;
    assign m_wstrb   = 4'hF;
    assign m_wvalid  = fire && !w_sent;

    wire aw_go = m_awvalid && m_awready;
    wire w_go  = m_wvalid  && m_wready;

    assign req_ready = fire && (aw_sent || aw_go) && (w_sent || w_go);

    assign m_bready   = 1'b1;
    assign done_valid = m_bvalid;
    assign done_err   = m_bvalid && (m_bresp != 2'b00);
    assign outstanding = cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_sent <= 1'b0;
            w_sent  <= 1'b0;
            cnt     <= 4'd0;
        end else begin
            if (req_ready) begin
                aw_sent <= 1'b0;
                w_sent  <= 1'b0;
            end else begin
                if (aw_go) aw_sent <= 1'b1;
                if (w_go)  w_sent  <= 1'b1;
            end

            case ({req_ready, m_bvalid && m_bready})
                2'b10:   cnt <= cnt + 4'd1;
                2'b01:   cnt <= cnt - 4'd1;
                default: cnt <= cnt;
            endcase
        end
    end

endmodule
