#!/usr/bin/env bash
# Elaborate the RTL at three distinct parameter sets to prove it is genuinely
# parameterized (no hard-coded widths).  Uses a tiny generated wrapper so the
# top parameters can be overridden without a testbench.
set -e
RTL="rtl/as_stat_update.v rtl/as_isqrt.v rtl/as_divide.v rtl/as_regfile.v rtl/alpha_signal_engine.v"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

elab () {
    local nsym=$1 symw=$2 frac=$3 isq=$4 div=$5
    cat > "$TMP/wrap.v" <<EOF
module wrap;
  wire clk=0, rst_n=0, s_tvalid=0, s_tlast=0, m_tready=0;
  wire [63:0] s_tdata=0;
  wire awvalid=0, wvalid=0, bready=0, arvalid=0, rready=0;
  wire [7:0] awaddr=0, araddr=0; wire [31:0] wdata=0; wire [3:0] wstrb=0;
  wire s_tready, m_tvalid, m_tlast, awready, wready, bvalid, arready, rvalid, irq;
  wire [255:0] m_tdata; wire [31:0] rdata; wire [1:0] bresp, rresp;
  alpha_signal_engine #(.N_SYM($nsym), .SYMW($symw), .FRAC($frac),
      .ISQRT_STAGES($isq), .DIV_WN($div)) d (
    .clk(clk),.rst_n(rst_n),.s_tvalid(s_tvalid),.s_tready(s_tready),
    .s_tdata(s_tdata),.s_tlast(s_tlast),.m_tvalid(m_tvalid),.m_tready(m_tready),
    .m_tdata(m_tdata),.m_tlast(m_tlast),.awaddr(awaddr),.awvalid(awvalid),
    .awready(awready),.wdata(wdata),.wstrb(wstrb),.wvalid(wvalid),.wready(wready),
    .bresp(bresp),.bvalid(bvalid),.bready(bready),.araddr(araddr),.arvalid(arvalid),
    .arready(arready),.rdata(rdata),.rresp(rresp),.rvalid(rvalid),.rready(rready),.irq(irq));
endmodule
EOF
    echo "== N_SYM=$nsym SYMW=$symw FRAC=$frac ISQRT=$isq DIV=$div =="
    iverilog -g2012 -o "$TMP/e.vvp" -s wrap $RTL "$TMP/wrap.v"
    echo "   elaborated OK"
}

elab 64  6 16 32 48
elab 32  5 16 32 48
elab 128 7 20 40 56
echo "all parameter sets elaborated cleanly"
