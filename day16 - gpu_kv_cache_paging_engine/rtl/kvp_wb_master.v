// ============================================================================
// kvp_wb_master.v - Wishbone B4 classic single-transaction master.
//
//   The core drives one request at a time (`m_req` held until `m_done`); this
//   module turns it into a classic Wishbone cycle:
//
//     CYC_O/STB_O asserted while the request is outstanding, SEL_O = 4'hF
//     (all accesses are naturally aligned 32-bit words), ACK_I terminates the
//     cycle.  A zero-wait-state slave may ACK in the very cycle STB_O is
//     asserted, which is what lets the engine sustain one transaction per clock;
//     any number of wait states simply stretches the cycle, and because the core
//     advances only on `m_done` the whole datapath stalls losslessly.
//
//   Two failure modes are folded into `m_err`:
//     - ERR_I from the slave (unmapped / faulting address)
//     - a TIMEOUT-cycle watchdog on a cycle that is never acknowledged, so a
//       hung interconnect cannot wedge the engine forever.
// ============================================================================
`default_nettype none

module kvp_wb_master #(
    parameter integer TIMEOUT = 256
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- core side ----
    input  wire        m_req,
    input  wire        m_we,
    input  wire [31:0] m_addr,
    input  wire [31:0] m_wdata,
    output wire        m_done,       // 1-cycle: transaction retired (ok or error)
    output wire        m_err,        // qualified by m_done
    output wire [31:0] m_rdata,      // valid with m_done on a read
    output reg  [31:0] m_xacts,      // completed bus transactions (diagnostics)

    // ---- Wishbone B4 classic master port ----
    output wire        wb_cyc_o,
    output wire        wb_stb_o,
    output wire        wb_we_o,
    output wire [31:0] wb_adr_o,
    output wire [31:0] wb_dat_o,
    output wire [3:0]  wb_sel_o,
    input  wire        wb_ack_i,
    input  wire [31:0] wb_dat_i,
    input  wire        wb_err_i
);
    localparam integer TW = (TIMEOUT <= 256) ? 9 : (TIMEOUT <= 4096) ? 13 : 17;

    assign wb_cyc_o = m_req;
    assign wb_stb_o = m_req;
    assign wb_we_o  = m_we;
    assign wb_adr_o = {m_addr[31:2], 2'b00};
    assign wb_dat_o = m_wdata;
    assign wb_sel_o = 4'hF;

    // ---- watchdog on an unacknowledged cycle ----
    reg [TW-1:0] wdog;
    wire         expired = (wdog >= TIMEOUT[TW-1:0]);
    always @(posedge clk) begin
        if (!rst_n)          wdog <= {TW{1'b0}};
        else if (!m_req)     wdog <= {TW{1'b0}};
        else if (m_done)     wdog <= {TW{1'b0}};
        else if (!expired)   wdog <= wdog + 1'b1;
    end

    assign m_done  = m_req && (wb_ack_i || wb_err_i || expired);
    assign m_err   = m_req && (wb_err_i || expired) && !wb_ack_i;
    assign m_rdata = wb_dat_i;

    always @(posedge clk) begin
        if (!rst_n)                  m_xacts <= 32'd0;
        else if (m_done && !m_err)   m_xacts <= m_xacts + 32'd1;
    end
endmodule

`default_nettype wire
