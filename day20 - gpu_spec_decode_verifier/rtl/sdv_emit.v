// ===========================================================================
// sdv_emit.v - egress AXI4-Stream master.
//
// Drains the result FIFO onto the 128-bit egress link, one beat per clock when
// the consumer is ready.  TLAST is carried through the FIFO with the data and
// marks the trailer beat, so a reader frames a job without needing to know how
// many tokens were accepted before it arrives.
// ===========================================================================
`default_nettype none

module sdv_emit (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          fifo_empty,
    input  wire [128:0]  fifo_dout,
    output wire          fifo_pop,
    output wire          m_tvalid,
    input  wire          m_tready,
    output wire [127:0]  m_tdata,
    output wire          m_tlast
);
    assign m_tvalid = !fifo_empty;
    assign m_tdata  = fifo_dout[127:0];
    assign m_tlast  = fifo_dout[128];
    assign fifo_pop = m_tvalid && m_tready;
endmodule
`default_nettype wire
