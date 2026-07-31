#!/usr/bin/env bash
# Elaborate the top at three distinct bit-buffer depths (BUFW) to prove the RTL
# is parameterised. The 4-lane datapath and 32-bit wire format are fixed; BUFW
# trades reader FIFO depth (and thus max ingress burst tolerance) for area.
set -e
cd "$(dirname "$0")/.."
RTL=$(ls rtl/*.v)
for B in 160 192 256; do
    echo "=== elaborate BUFW=$B ==="
    if iverilog -g2012 -Pbitpack_decode_engine.BUFW=$B \
        -o /tmp/bpd_elab_$B.vvp -s bitpack_decode_engine $RTL 2>&1; then
        echo "  BUFW=$B: elaborated OK"
        rm -f /tmp/bpd_elab_$B.vvp
    else
        echo "  BUFW=$B: FAILED"; exit 1
    fi
done
echo "all parameter sets elaborated"
