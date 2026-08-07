#!/usr/bin/env bash
# Full differential simulation at several geometries. Each one rebuilds the
# host program, regenerates the whole experiment for that geometry and runs all
# three passes, so nothing is reused between points - a parameter that only
# works at the default would fail here.
set -e
cd "$(dirname "$0")/.."

CC=${CC:-cc}
IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}

# MTU  QP  RX_BUFS
POINTS=(
  "16 4 4"
  "32 2 4"
  "8  8 8"
  "64 4 2"
)

mkdir -p results
total_checks=0
total_fails=0

for pt in "${POINTS[@]}"; do
    set -- $pt
    MTU=$1; QP=$2; BUFS=$3
    tag="mtu${MTU}_qp${QP}_buf${BUFS}"
    out="results/sweep_${tag}"
    mkdir -p "$out"

    D="-DP2P_MTU_WORDS=$MTU -DP2P_NUM_QP=$QP -DP2P_RX_BUFS=$BUFS"

    echo "=== $tag ==="
    $CC -std=c11 -O2 -Wall -Wextra $D -o "$out/p2p_host" \
        sw/p2p_host.c sw/p2p_model.c sw/p2p_baseline.c
    ./"$out/p2p_host" --outdir "$out" > /dev/null
    $IVERILOG -g2012 $D -o "$out/sim.vvp" -s p2p_tb -Irtl -I"$out" \
        rtl/*.v tb/p2p_tb.sv
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
