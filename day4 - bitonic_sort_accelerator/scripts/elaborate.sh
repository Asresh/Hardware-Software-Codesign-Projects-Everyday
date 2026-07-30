#!/usr/bin/env bash
# Elaborate the RTL at three distinct parameter sets to prove the design is
# genuinely parameterized (not hard-wired to one geometry). Each run writes a
# tiny generated params header, elaborates with Icarus, and reports pass/fail.
set -u

RTL=$(ls rtl/*.v)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# N W ADDR_WIDTH TILE_WIDTH
CONFIGS=(
    "8  32 18 16"
    "16 32 20 16"
    "32 32 22 16"
)

fail=0
for cfg in "${CONFIGS[@]}"; do
    set -- $cfg
    N=$1; W=$2; AW=$3; TW=$4
    cat > "$TMP/params.vh" <<EOF
localparam integer N          = $N;
localparam integer W          = $W;
localparam integer ADDR_WIDTH = $AW;
localparam integer TILE_WIDTH = $TW;
localparam integer MEM_WORDS  = 65536;
EOF
    # tiny elaboration wrapper that instantiates sort_top at this geometry
    cat > "$TMP/elab_top.v" <<EOF
\`default_nettype none
module elab_top;
\`include "params.vh"
    reg clk=0, rst_n=0;
    reg mmio_sel=0, mmio_write=0; reg [7:0] mmio_addr=0; reg [31:0] mmio_wdata=0;
    wire [31:0] mmio_rdata;
    wire mem_rd_en; wire [ADDR_WIDTH-1:0] mem_rd_addr; reg [N*W-1:0] mem_rd_data=0;
    wire mem_wr_en; wire [ADDR_WIDTH-1:0] mem_wr_addr; wire [N*W-1:0] mem_wr_data;
    wire irq;
    sort_top #(.N(N), .W(W), .ADDR_WIDTH(ADDR_WIDTH), .TILE_WIDTH(TILE_WIDTH)) u (
        .clk(clk), .rst_n(rst_n), .mmio_sel(mmio_sel), .mmio_write(mmio_write),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_data(mem_rd_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
        .irq(irq));
endmodule
EOF
    if iverilog -g2012 -Wall -o "$TMP/elab.vvp" -s elab_top \
        -I"$TMP" $RTL "$TMP/elab_top.v" 2> "$TMP/err.log"; then
        echo "ELAB OK   N=$N W=$W ADDR_WIDTH=$AW TILE_WIDTH=$TW"
    else
        echo "ELAB FAIL N=$N W=$W ADDR_WIDTH=$AW TILE_WIDTH=$TW"
        cat "$TMP/err.log"
        fail=1
    fi
done

exit $fail
