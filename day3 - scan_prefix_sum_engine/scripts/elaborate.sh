#!/usr/bin/env bash
# Elaborate the RTL at three distinct parameter sets to prove the design is
# genuinely parameterized (not hard-wired to one geometry). Each run writes a
# tiny generated params header, elaborates with Icarus, and reports pass/fail.
set -u

RTL=$(ls rtl/*.v)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# LANES W ADDR_WIDTH LEN_WIDTH
CONFIGS=(
    "8  32 18 18"
    "16 32 20 20"
    "32 32 22 22"
)

fail=0
for cfg in "${CONFIGS[@]}"; do
    set -- $cfg
    LANES=$1; W=$2; AW=$3; LW=$4
    cat > "$TMP/params.vh" <<EOF
localparam integer LANES      = $LANES;
localparam integer W          = $W;
localparam integer ADDR_WIDTH = $AW;
localparam integer LEN_WIDTH  = $LW;
localparam integer MEM_WORDS  = 65536;
EOF
    # tiny elaboration wrapper that instantiates scan_top at this geometry
    cat > "$TMP/elab_top.v" <<EOF
\`default_nettype none
module elab_top;
\`include "params.vh"
    reg clk=0, rst_n=0;
    reg psel=0, penable=0, pwrite=0; reg [7:0] paddr=0; reg [31:0] pwdata=0;
    wire [31:0] prdata; wire pready;
    wire mem_rd_en; wire [ADDR_WIDTH-1:0] mem_rd_addr; reg [LANES*W-1:0] mem_rd_data=0;
    wire mem_wr_en; wire [ADDR_WIDTH-1:0] mem_wr_addr; wire [LANES*W-1:0] mem_wr_data;
    wire [LANES-1:0] mem_wr_be; wire irq;
    scan_top #(.LANES(LANES), .W(W), .ADDR_WIDTH(ADDR_WIDTH), .LEN_WIDTH(LEN_WIDTH)) u (
        .clk(clk), .rst_n(rst_n), .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata), .prdata(prdata), .pready(pready),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_data(mem_rd_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
        .mem_wr_be(mem_wr_be), .irq(irq));
endmodule
EOF
    if iverilog -g2012 -Wall -o "$TMP/elab.vvp" -s elab_top \
        -I"$TMP" $RTL "$TMP/elab_top.v" 2> "$TMP/err.log"; then
        echo "ELAB OK   LANES=$LANES W=$W ADDR_WIDTH=$AW LEN_WIDTH=$LW"
    else
        echo "ELAB FAIL LANES=$LANES W=$W ADDR_WIDTH=$AW LEN_WIDTH=$LW"
        cat "$TMP/err.log"
        fail=1
    fi
done

exit $fail
