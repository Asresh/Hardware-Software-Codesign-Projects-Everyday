#!/usr/bin/env bash
# Elaborate the RTL at three distinct parameter sets to prove the design is
# genuinely parameterized (not hard-wired to one lane count). Each run writes a
# tiny generated params header, elaborates with Icarus, and reports pass/fail.
set -u

RTL=$(ls rtl/*.v)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# LANES ROUNDS ADDR_WIDTH
CONFIGS=(
    "1  10 18"
    "4  10 20"
    "8   7 22"
)

fail=0
for cfg in "${CONFIGS[@]}"; do
    set -- $cfg
    LANES=$1; ROUNDS=$2; AW=$3
    cat > "$TMP/params.vh" <<EOF
localparam integer LANES      = $LANES;
localparam integer ROUNDS     = $ROUNDS;
localparam integer WORD_W     = $((LANES*128));
localparam integer WPB        = $((LANES*4));
localparam integer ADDR_WIDTH = $AW;
localparam integer MEM_WORDS  = 262144;
localparam [31:0]  IDENT_VALUE = 32'h5B160006;
EOF
    cat > "$TMP/elab_top.v" <<'EOF'
`default_nettype none
module elab_top;
`include "params.vh"
    reg clk=0, rst_n=0;
    reg mmio_sel=0, mmio_write=0; reg [7:0] mmio_addr=0; reg [31:0] mmio_wdata=0;
    wire [31:0] mmio_rdata;
    wire mem_wr_en; wire [ADDR_WIDTH-1:0] mem_wr_addr;
    wire [WORD_W-1:0] mem_wr_data; wire [WPB-1:0] mem_wr_mask;
    wire irq;
    philox_top #(.LANES(LANES), .ROUNDS(ROUNDS), .ADDR_WIDTH(ADDR_WIDTH)) u (
        .clk(clk), .rst_n(rst_n), .mmio_sel(mmio_sel), .mmio_write(mmio_write),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr),
        .mem_wr_data(mem_wr_data), .mem_wr_mask(mem_wr_mask), .irq(irq));
endmodule
EOF
    if iverilog -g2012 -Wall -o "$TMP/elab.vvp" -s elab_top \
        -I"$TMP" $RTL "$TMP/elab_top.v" 2> "$TMP/err.log"; then
        echo "ELAB OK   LANES=$LANES ROUNDS=$ROUNDS ADDR_WIDTH=$AW"
    else
        echo "ELAB FAIL LANES=$LANES ROUNDS=$ROUNDS ADDR_WIDTH=$AW"
        grep -i error "$TMP/err.log"
        fail=1
    fi
done

exit $fail
