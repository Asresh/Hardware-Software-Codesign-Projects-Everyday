#!/usr/bin/env bash
# Full differential simulation at several geometries. Each one rebuilds the host
# program, regenerates the whole experiment for that geometry and runs all five
# passes, so nothing is reused between points - a parameter that only works at
# the default would fail here.
#
# MAX_NODES and MAX_DEPTH are the two that matter: the first sets the width of
# the candidate mask and therefore the depth of the argmax tree, the second the
# cap on the accepted path and the size of the histogram. 128x16 makes the tree
# one level deeper than the default, 32x8 and 16x4 shrink both, and 64x4 pins a
# wide tree against a shallow cap so almost every job clamps.
set -e
cd "$(dirname "$0")/.."

CC=${CC:-cc}
IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}

# MAX_NODES  MAX_DEPTH
POINTS=(
  "64  16"
  "128 16"
  "32  8"
  "64  4"
  "16  4"
)

mkdir -p results
total_checks=0
total_fails=0

for pt in "${POINTS[@]}"; do
    set -- $pt
    NODES=$1; DEPTH=$2
    tag="n${NODES}_d${DEPTH}"
    out="results/sweep_${tag}"
    mkdir -p "$out"

    D="-DSDV_MAX_NODES=$NODES -DSDV_MAX_DEPTH=$DEPTH"

    echo "=== $tag ==="
    $CC -std=c11 -O2 -Wall -Wextra $D -o "$out/sdv_host" \
        sw/sdv_host.c sw/sdv_model.c sw/sdv_baseline.c
    ./"$out/sdv_host" --outdir "$out" > /dev/null
    $IVERILOG -g2012 $D -o "$out/sim.vvp" -s sdv_tb -Irtl -I"$out" \
        rtl/*.v tb/sdv_tb.sv
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
