#!/usr/bin/env bash
# Elaborate the RTL at three distinct parameter sets to prove it is genuinely
# parameterized. Uses Icarus Verilog (no testbench, top = order_book_engine).
set -e
cd "$(dirname "$0")/.."

RTL="rtl/ob_msg_decode.v rtl/ob_cam.v rtl/ob_bbo_reduce.v rtl/ob_regfile.v rtl/order_book_engine.v"

elab() {
    local pw=$1 qw=$2 n=$3
    echo "== elaborate PW=$pw QW=$qw N_LEVELS=$n =="
    iverilog -g2012 -o /dev/null -s order_book_engine \
        -Porder_book_engine.PW=$pw \
        -Porder_book_engine.QW=$qw \
        -Porder_book_engine.N=$n \
        $RTL
    echo "   ok"
}

elab 16 24 32     # default
elab 20 32 64     # deeper book, wider price/qty
elab 12 16 16     # compact configuration
echo "all parameter sets elaborated cleanly"
