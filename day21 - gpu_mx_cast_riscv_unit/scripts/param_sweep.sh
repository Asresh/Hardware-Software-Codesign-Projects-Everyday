#!/usr/bin/env bash
# Full differential simulation at several geometries. Each point rebuilds the
# host program, regenerates the entire experiment for that geometry and runs
# both passes, so nothing is reused between points - a parameter that only
# works at the default fails here.
#
# IMEM_W and DMEM_W are the two the RTL sees: they set the size of both RAMs
# and, with them, the exact addresses at which a fetch or a load has to trap,
# so the trap programs are aimed at a different boundary at every point. BLK is
# the MX block size the software uses; 16 and 64 change how many elements share
# a scale and therefore the whole shape of both kernels, without the hardware
# being told anything.
set -e
cd "$(dirname "$0")/.."

CC=${CC:-cc}
IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}

SRC="sw/mxq_host.c sw/mxq_model.c sw/mxq_baseline.c sw/mxq_iss.c sw/mxq_asm.c sw/mxq_kernels.c"

# IMEM_W  DMEM_W  BLK
POINTS=(
  "12 12 32"
  "13 12 32"
  "12 13 64"
  "11 11 16"
  "12 12 16"
)

mkdir -p results
total_checks=0
total_fails=0

for pt in "${POINTS[@]}"; do
    set -- $pt
    IW=$1; DW=$2; BK=$3
    tag="i${IW}_d${DW}_b${BK}"
    out="results/sweep_${tag}"
    mkdir -p "$out"

    CD="-DMXQ_IMEM_W=$IW -DMXQ_DMEM_W=$DW -DMXQ_BLK=$BK"
    VD="-DMXQ_IMEM_W=$IW -DMXQ_DMEM_W=$DW"

    echo "=== $tag ==="
    $CC -std=c11 -O2 -Wall -Wextra $CD -o "$out/mxq_host" $SRC -lm
    ./"$out/mxq_host" --outdir "$out" > /dev/null
    $IVERILOG -g2012 $VD -o "$out/sim.vvp" -s mxq_tb -Irtl -I"$out" \
        rtl/*.v tb/mxq_tb.sv
    ( cd "$out" && $VVP sim.vvp > sim.log 2>&1 )

    if ! grep -q "TEST PASSED" "$out/sim.log"; then
        echo "FAILED at $tag"
        tail -20 "$out/sim.log"
        exit 1
    fi
    line=$(grep "^RESULT" "$out/sim.log")
    c=$(echo "$line" | sed -n 's/.*checks=\([0-9]*\).*/\1/p')
    f=$(echo "$line" | sed -n 's/.*fails=\([0-9]*\).*/\1/p')
    total_checks=$((total_checks + c))
    total_fails=$((total_fails + f))
    echo "  $line"
done

echo ""
echo "SWEEP TOTAL checks=$total_checks fails=$total_fails"
[ "$total_fails" -eq 0 ] && echo "SWEEP PASSED" || { echo "SWEEP FAILED"; exit 1; }
