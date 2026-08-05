// ============================================================================
// emb_axi_read - AXI4 burst read master, one outstanding transaction.
//
// Accepts {addr, len} requests from the core, drives a single INCR burst on the
// AR channel, and forwards the R channel to the consumer as an elastic
// valid/ready stream.  Backpressure from the consumer is passed straight to
// RREADY, so a stalled consumer stalls the burst instead of dropping beats.
//
// A SLVERR/DECERR response raises `err` for one cycle; the burst is still drained
// to RLAST so the slave and this master stay in step (AXI4 requires the full
// burst regardless of the response).  A watchdog raises `timeout` if a request
// makes no progress for WDOG cycles, so a wedged slave aborts the run instead
// of hanging it.
// ============================================================================
`include "emb_defs.vh"

module emb_axi_read #(
    parameter DW   = 128,          // data-bus width in bits (LANES*32)
    parameter AW   = 32,           // address width in bits
    parameter WDOG = `EMB_WDOG
) (
    input  wire            clk,
    input  wire            rst,

    // ---- request port (from the core) ----------------------------------
    input  wire            req_valid,
    output wire            req_ready,
    input  wire [AW-1:0]   req_addr,   // byte address, beat aligned
    input  wire [7:0]      req_len,    // beats - 1 (AXI4 ARLEN)

    // ---- AXI4 read address channel -------------------------------------
    output wire            m_arvalid,
    input  wire            m_arready,
    output wire [AW-1:0]   m_araddr,
    output wire [7:0]      m_arlen,
    output wire [2:0]      m_arsize,
    output wire [1:0]      m_arburst,

    // ---- AXI4 read data channel ----------------------------------------
    input  wire            m_rvalid,
    output wire            m_rready,
    input  wire [DW-1:0]   m_rdata,
    input  wire [1:0]      m_rresp,
    input  wire            m_rlast,

    // ---- beat stream to the consumer -----------------------------------
    output wire            d_valid,
    input  wire            d_ready,
    output wire [DW-1:0]   d_data,
    output wire            d_last,

    output reg             err,        // pulse: non-OKAY response
    output reg             timeout,    // pulse: watchdog expired
    output wire            busy
);
    // ARSIZE encodes log2(bytes per beat); DW is a power-of-two multiple of 32.
    function integer clog2b;
        input integer v;
        integer i;
        begin
            clog2b = 0;
            for (i = v; i > 1; i = i >> 1) clog2b = clog2b + 1;
        end
    endfunction
    localparam integer SIZE = clog2b(DW / 8);

    assign m_arsize  = SIZE[2:0];
    assign m_arburst = 2'b01;          // INCR

    localparam S_IDLE = 2'd0, S_ADDR = 2'd1, S_DATA = 2'd2;
    reg [1:0] state;

    reg [AW-1:0] addr_q;
    reg [7:0]    len_q;
    reg [31:0]   wd;

    assign req_ready = (state == S_IDLE) && !rst;
    assign busy      = (state != S_IDLE);

    // The address is presented on AR in the same cycle the request is accepted,
    // so a row burst starts one cycle after the sequencer asks for it rather than
    // two.  With back-to-back row gathers that single cycle is 6 % of a
    // CHUNKS=16 burst, which is worth the bypass mux.
    assign m_arvalid = (state == S_ADDR) || ((state == S_IDLE) && req_valid && !rst);
    assign m_araddr  = (state == S_IDLE) ? req_addr : addr_q;
    assign m_arlen   = (state == S_IDLE) ? req_len  : len_q;

    // R channel forwarded verbatim; the consumer's ready gates RREADY
    assign m_rready = (state == S_DATA) && d_ready;
    assign d_valid  = (state == S_DATA) && m_rvalid;
    assign d_data   = m_rdata;
    assign d_last   = m_rlast;

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            addr_q  <= {AW{1'b0}};
            len_q   <= 8'd0;
            err     <= 1'b0;
            timeout <= 1'b0;
            wd      <= 32'd0;
        end else begin
            err     <= 1'b0;
            timeout <= 1'b0;

            case (state)
            S_IDLE: begin
                if (req_valid) begin
                    addr_q <= req_addr;
                    len_q  <= req_len;
                    wd     <= 32'd0;
                    // the AR beat is already on the bus this cycle: if the slave
                    // took it, go straight to the data phase
                    state  <= m_arready ? S_DATA : S_ADDR;
                end
            end

            S_ADDR: begin
                if (m_arready) begin
                    state <= S_DATA;
                    wd    <= 32'd0;
                end else begin
                    wd <= wd + 32'd1;
                    if (wd >= WDOG - 1) begin
                        timeout <= 1'b1;
                        state   <= S_IDLE;
                    end
                end
            end

            S_DATA: begin
                if (m_rvalid && m_rready) begin
                    wd <= 32'd0;
                    if (m_rresp != 2'b00) err <= 1'b1;
                    if (m_rlast) state <= S_IDLE;
                end else if (m_rvalid) begin
                    // the slave is presenting data and we are backpressuring it:
                    // legitimate, so the watchdog stays parked
                    wd <= 32'd0;
                end else begin
                    wd <= wd + 32'd1;
                    if (wd >= WDOG - 1) begin
                        timeout <= 1'b1;
                        state   <= S_IDLE;
                    end
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
