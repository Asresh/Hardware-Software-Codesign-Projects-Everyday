// ============================================================================
// kds_axil_master - pipelined AXI4-Lite master for the graph fetch and the
//                   result writeback.
//
// AXI4-Lite has no bursts, so the only way to keep a sequential array read at
// bus rate is to keep several transactions in flight: the address channel runs
// ahead while data comes back behind it. This master therefore does not
// serialise address-then-data - it passes the core's request straight onto AR
// (or AW/W) and reports returning data on a separate valid, leaving the core to
// count how many it has outstanding. With a zero-wait slave that is one word
// per clock; the core caps the outstanding count so the slave never sees more
// than it can queue.
//
// Reads return strictly in order, which is guaranteed for a single-ID AXI4-Lite
// master, so the core can match the Nth returning word to the Nth address it
// issued without carrying tags.
//
// A write beat holds AW and W until *both* have handshaken - a slave may take
// them in either order or in different cycles - and reports completion only on
// B, so a SLVERR on a write is never missed.
// ============================================================================
`include "kds_defs.vh"

module kds_axil_master (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clr,          // drop the sticky bus-error flag

    // ---- read request port -------------------------------------------------
    input  wire        rd_req,
    input  wire [31:0] rd_addr,
    output wire        rd_gnt,       // address accepted this cycle
    output wire        rd_valid,     // a data word is on rd_data this cycle
    output wire [31:0] rd_data,

    // ---- write request port ------------------------------------------------
    input  wire        wr_req,
    input  wire [31:0] wr_addr,
    input  wire [31:0] wr_wdata,
    output wire        wr_gnt,       // beat fully accepted this cycle
    output wire        wr_done,      // a B response landed this cycle

    output reg         err,

    // ---- AXI4-Lite master --------------------------------------------------
    output wire [31:0] m_awaddr,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,
    output wire [31:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output wire        m_rready
);

    // ------------------------------------------------------------------ reads
    assign m_arvalid = rd_req;
    assign m_araddr  = rd_addr;
    assign m_rready  = 1'b1;
    assign rd_gnt    = rd_req & m_arready;
    assign rd_valid  = m_rvalid;
    assign rd_data   = m_rdata;

    // ----------------------------------------------------------------- writes
    reg aw_taken, w_taken;

    assign m_awvalid = wr_req & ~aw_taken;
    assign m_awaddr  = wr_addr;
    assign m_wvalid  = wr_req & ~w_taken;
    assign m_wdata   = wr_wdata;
    assign m_wstrb   = 4'hF;
    assign m_bready  = 1'b1;

    wire aw_hs = m_awvalid & m_awready;
    wire w_hs  = m_wvalid  & m_wready;

    assign wr_gnt  = wr_req & (aw_taken | aw_hs) & (w_taken | w_hs);
    assign wr_done = m_bvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_taken <= 1'b0;
            w_taken  <= 1'b0;
            err      <= 1'b0;
        end else begin
            if (wr_gnt) begin
                aw_taken <= 1'b0;
                w_taken  <= 1'b0;
            end else begin
                if (aw_hs) aw_taken <= 1'b1;
                if (w_hs ) w_taken  <= 1'b1;
            end

            if (clr) err <= 1'b0;
            else if ((m_rvalid && m_rresp != 2'b00) ||
                     (m_bvalid && m_bresp != 2'b00)) err <= 1'b1;
        end
    end

endmodule
