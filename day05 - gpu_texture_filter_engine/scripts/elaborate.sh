#!/usr/bin/env bash
# Elaborate the RTL at three distinct parameter sets to prove the design is
# genuinely parameterized (not hard-wired to one geometry). Each run writes a
# tiny generated params header, elaborates with Icarus, and reports pass/fail.
set -u

RTL=$(ls rtl/*.v)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# WMAX ADDR_WIDTH
CONFIGS=(
    "32  18"
    "64  20"
    "128 22"
)

fail=0
for cfg in "${CONFIGS[@]}"; do
    set -- $cfg
    WMAX=$1; AW=$2
    cat > "$TMP/params.vh" <<EOF
localparam integer PIX_W      = 8;
localparam integer PPW        = 4;
localparam integer WORD_W     = 32;
localparam integer ADDR_WIDTH = $AW;
localparam integer WMAX       = $WMAX;
localparam integer IDXW       = 16;
localparam integer MEM_WORDS  = 65536;
EOF
    cat > "$TMP/elab_top.v" <<'EOF'
`default_nettype none
module elab_top;
`include "params.vh"
    reg clk=0, rst_n=0;
    reg mmio_sel=0, mmio_write=0; reg [7:0] mmio_addr=0; reg [31:0] mmio_wdata=0;
    wire [31:0] mmio_rdata;
    wire mem_rd_en; wire [ADDR_WIDTH-1:0] mem_rd_addr; reg [WORD_W-1:0] mem_rd_data=0;
    wire mem_wr_en; wire [ADDR_WIDTH-1:0] mem_wr_addr; wire [WORD_W-1:0] mem_wr_data;
    wire irq;
    tex_top #(.PIX_W(PIX_W), .PPW(PPW), .ADDR_WIDTH(ADDR_WIDTH),
              .WMAX(WMAX), .IDXW(IDXW)) u (
        .clk(clk), .rst_n(rst_n), .mmio_sel(mmio_sel), .mmio_write(mmio_write),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_data(mem_rd_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
        .irq(irq));
endmodule
EOF
    if iverilog -g2012 -Wall -o "$TMP/elab.vvp" -s elab_top \
        -I"$TMP" $RTL "$TMP/elab_top.v" 2> "$TMP/err.log"; then
        echo "ELAB OK   WMAX=$WMAX ADDR_WIDTH=$AW"
    else
        echo "ELAB FAIL WMAX=$WMAX ADDR_WIDTH=$AW"
        cat "$TMP/err.log"
        fail=1
    fi
done

exit $fail
