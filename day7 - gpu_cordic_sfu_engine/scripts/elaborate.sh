#!/usr/bin/env bash
# Elaborate the RTL at three distinct parameter sets to prove the design is
# genuinely parameterized (not hard-wired to one lane count). Each run writes a
# tiny generated params header plus the fixed CORDIC-constant header, elaborates
# with Icarus, and reports pass/fail.
set -u

RTL=$(ls rtl/*.v)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# the algorithm-fixed CORDIC constants (identical across every elaboration)
cat > "$TMP/sfu_const.vh" <<'EOF'
localparam integer FBITS       = 28;
localparam integer NC          = 28;
localparam integer NH          = 29;
localparam integer NROM        = 57;
localparam integer WORKW       = 40;
localparam signed [31:0] INV_KC = 32'sh09B74EDB;
localparam signed [31:0] INV_KH = 32'sh1351E872;
localparam signed [31:0] ONE_Q  = 32'sh10000000;
localparam signed [31:0] QTR_Q  = 32'sh04000000;
EOF

# LANES ADDR_WIDTH
CONFIGS=(
    "1  18"
    "4  20"
    "8  22"
)

fail=0
for cfg in "${CONFIGS[@]}"; do
    set -- $cfg
    LANES=$1; AW=$2
    cat > "$TMP/elab_top.v" <<EOF
\`default_nettype none
module elab_top;
    localparam integer LANES = $LANES;
    localparam integer ADDR_WIDTH = $AW;
    localparam integer ENTRY_WORDS = 4;
    reg clk=0, rst_n=0;
    reg mmio_sel=0, mmio_write=0; reg [7:0] mmio_addr=0; reg [31:0] mmio_wdata=0;
    wire [31:0] mmio_rdata;
    wire mem_rd_en; wire [LANES*ADDR_WIDTH-1:0] mem_rd_addr; wire [LANES-1:0] mem_rd_mask;
    reg  [LANES*128-1:0] mem_rd_data=0;
    wire mem_wr_en; wire [LANES*ADDR_WIDTH-1:0] mem_wr_addr; wire [LANES-1:0] mem_wr_mask;
    wire [LANES*128-1:0] mem_wr_data;
    wire irq;
    sfu_top #(.LANES(LANES), .ADDR_WIDTH(ADDR_WIDTH), .ENTRY_WORDS(ENTRY_WORDS),
              .ROMFILE("tb/vectors/cordic_rom.hex")) u (
        .clk(clk), .rst_n(rst_n), .mmio_sel(mmio_sel), .mmio_write(mmio_write),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .mem_rd_en(mem_rd_en), .mem_rd_addr(mem_rd_addr), .mem_rd_mask(mem_rd_mask),
        .mem_rd_data(mem_rd_data),
        .mem_wr_en(mem_wr_en), .mem_wr_addr(mem_wr_addr), .mem_wr_mask(mem_wr_mask),
        .mem_wr_data(mem_wr_data), .irq(irq));
endmodule
EOF
    if iverilog -g2012 -Wall -o "$TMP/elab.vvp" -s elab_top \
        -I"$TMP" $RTL "$TMP/elab_top.v" 2> "$TMP/err.log"; then
        echo "ELAB OK   LANES=$LANES ADDR_WIDTH=$AW"
    else
        echo "ELAB FAIL LANES=$LANES ADDR_WIDTH=$AW"
        grep -i error "$TMP/err.log"
        fail=1
    fi
done

exit $fail
