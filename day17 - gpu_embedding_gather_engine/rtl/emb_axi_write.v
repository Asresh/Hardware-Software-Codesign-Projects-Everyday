// ============================================================================
// emb_axi_write - AXI4 burst write master, one outstanding transaction.
//
// Accepts a {addr, len} request, issues the AW beat, then streams W beats from
// the producer (`s_*`) with WLAST on the final beat and all byte strobes set,
// and finally collects the B response.  The W beats are allowed to lag the AW
// handshake arbitrarily, which is what lets the drain stage of the accumulator
// run its divider pass after the address has already been placed on the bus.
//
// `done` pulses when the B response for the burst lands; `err` pulses if that
// response is not OKAY; `timeout` pulses if the slave stalls the transaction
// past WDOG cycles of no progress.
// ============================================================================
`include "emb_defs.vh"

module emb_axi_write #(
    parameter DW   = 128,
    parameter AW   = 32,
    parameter WDOG = `EMB_WDOG
) (
    input  wire            clk,
    input  wire            rst,

    // ---- request port ---------------------------------------------------
    input  wire            req_valid,
    output wire            req_ready,
    input  wire [AW-1:0]   req_addr,
    input  wire [7:0]      req_len,     // beats - 1

    // ---- producer beat stream ------------------------------------------
    input  wire            s_valid,
    output wire            s_ready,
    input  wire [DW-1:0]   s_data,

    // ---- AXI4 write address channel ------------------------------------
    output reg             m_awvalid,
    input  wire            m_awready,
    output reg  [AW-1:0]   m_awaddr,
    output reg  [7:0]      m_awlen,
    output wire [2:0]      m_awsize,
    output wire [1:0]      m_awburst,

    // ---- AXI4 write data channel ---------------------------------------
    output wire            m_wvalid,
    input  wire            m_wready,
    output wire [DW-1:0]   m_wdata,
    output wire [DW/8-1:0] m_wstrb,
    output wire            m_wlast,

    // ---- AXI4 write response channel -----------------------------------
    input  wire            m_bvalid,
    output wire            m_bready,
    input  wire [1:0]      m_bresp,

    output reg             done,
    output reg             err,
    output reg             timeout,
    output wire            busy
);
    function integer clog2b;
        input integer v;
        integer i;
        begin
            clog2b = 0;
            for (i = v; i > 1; i = i >> 1) clog2b = clog2b + 1;
        end
    endfunction
    localparam integer SIZE = clog2b(DW / 8);

    assign m_awsize  = SIZE[2:0];
    assign m_awburst = 2'b01;

    localparam S_IDLE = 2'd0, S_ADDR = 2'd1, S_DATA = 2'd2, S_RESP = 2'd3;
    reg [1:0] state;
    reg [7:0] beat;      // beats already accepted
    reg [7:0] len_q;
    reg [31:0] wd;

    assign req_ready = (state == S_IDLE) && !rst;
    assign busy      = (state != S_IDLE);

    assign m_wvalid = (state == S_DATA) && s_valid;
    assign s_ready  = (state == S_DATA) && m_wready;
    assign m_wdata  = s_data;
    assign m_wstrb  = {(DW/8){1'b1}};
    assign m_wlast  = (state == S_DATA) && (beat == len_q);
    assign m_bready = (state == S_RESP);

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            m_awvalid <= 1'b0;
            m_awaddr  <= {AW{1'b0}};
            m_awlen   <= 8'd0;
            beat      <= 8'd0;
            len_q     <= 8'd0;
            done      <= 1'b0;
            err       <= 1'b0;
            timeout   <= 1'b0;
            wd        <= 32'd0;
        end else begin
            done    <= 1'b0;
            err     <= 1'b0;
            timeout <= 1'b0;

            case (state)
            S_IDLE: begin
                if (req_valid) begin
                    m_awaddr  <= req_addr;
                    m_awlen   <= req_len;
                    len_q     <= req_len;
                    m_awvalid <= 1'b1;
                    beat      <= 8'd0;
                    state     <= S_ADDR;
                    wd        <= 32'd0;
                end
            end

            S_ADDR: begin
                if (m_awready) begin
                    m_awvalid <= 1'b0;
                    state     <= S_DATA;
                    wd        <= 32'd0;
                end else begin
                    wd <= wd + 32'd1;
                    if (wd >= WDOG - 1) begin
                        m_awvalid <= 1'b0;
                        timeout   <= 1'b1;
                        state     <= S_IDLE;
                    end
                end
            end

            S_DATA: begin
                if (m_wvalid && m_wready) begin
                    wd <= 32'd0;
                    if (beat == len_q) begin
                        state <= S_RESP;
                        beat  <= 8'd0;
                    end else begin
                        beat <= beat + 8'd1;
                    end
                end else if (!s_valid) begin
                    // the producer has not got the beat ready yet (the divider
                    // pass is still running): not a bus stall, park the watchdog
                    wd <= 32'd0;
                end else begin
                    wd <= wd + 32'd1;
                    if (wd >= WDOG - 1) begin
                        timeout <= 1'b1;
                        state   <= S_IDLE;
                    end
                end
            end

            S_RESP: begin
                if (m_bvalid) begin
                    if (m_bresp != 2'b00) err <= 1'b1;
                    done  <= 1'b1;
                    state <= S_IDLE;
                    wd    <= 32'd0;
                end else begin
                    wd <= wd + 32'd1;
                    if (wd >= WDOG - 1) begin
                        timeout <= 1'b1;
                        state   <= S_IDLE;
                    end
                end
            end
            endcase
        end
    end
endmodule
