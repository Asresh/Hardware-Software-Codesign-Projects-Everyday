#!/usr/bin/env bash
# Full differential simulation at four geometries.  Each entry rebuilds the
# golden model and the RTL from the same parameters and runs the whole
# testbench, so a pass means the design is bit-exact at that geometry - not
# just that it elaborates.
set -u

cd "$(dirname "$0")/.."

# DIM LANES MAX_BAG
CONFIGS=(
  "64 4 64"
  "32 8 32"
  "128 4 48"
  "32 2 64"
)

fail=0
echo "geometry sweep: DIM / LANES / MAX_BAG"
echo "-------------------------------------------------------------------"

for cfg in "${CONFIGS[@]}"; do
    set -- $cfg
    dim=$1; lanes=$2; bag=$3
    tag="sweep_${dim}x${lanes}x${bag}"
    out="results/${tag}"
    mkdir -p "$out"

    cc -std=c11 -O2 -Wall -Wextra \
       -DEMB_DIM=$dim -DEMB_LANES=$lanes -DEMB_MAX_BAG=$bag \
       -o "$out/emb_host" sw/emb_host.c sw/emb_model.c sw/emb_baseline.c \
       2> "$out/cc.log" || { echo "  $dim/$lanes/$bag  BUILD FAILED"; fail=1; continue; }

    "./$out/emb_host" --outdir "$out" > "$out/gen.log" 2>&1 \
        || { echo "  $dim/$lanes/$bag  GEN FAILED"; fail=1; continue; }

    iverilog -g2012 -DEMB_DIM=$dim -DEMB_LANES=$lanes -DEMB_MAX_BAG=$bag \
        -o "$out/emb_sim.vvp" -s emb_tb -Irtl -I"$out" rtl/*.v tb/emb_tb.sv \
        2> "$out/elab.log" || { echo "  $dim/$lanes/$bag  ELAB FAILED"; fail=1; continue; }

    ( cd "$out" && vvp emb_sim.vvp > sim.log 2>&1 )

    if grep -q "TEST PASSED" "$out/sim.log"; then
        chk=$(grep -o 'METRIC checks [0-9]*' "$out/sim.log" | awk '{print $3}')
        cf=$(grep -o 'METRIC cycles_full [0-9]*' "$out/sim.log" | awk '{print $3}')
        cs=$(grep -o 'METRIC cycles_single [0-9]*' "$out/sim.log" | awk '{print $3}')
        lr=$(grep -o 'METRIC local_rows [0-9]*' "$out/sim.log" | awk '{print $3}')
        sust=$(python3 -c "print(f'{$lr*$dim/$cf:.3f}')")
        db=$(python3 -c "print(f'{$cs/$cf:.3f}')")
        printf "  %3s / %-2s / %-3s  PASSED  %8s checks  %8s cycles  %s words/clk  dbuf %sx\n" \
               "$dim" "$lanes" "$bag" "$chk" "$cf" "$sust" "$db"
    else
        echo "  $dim/$lanes/$bag  FAILED (see $out/sim.log)"
        fail=1
    fi
done

echo "-------------------------------------------------------------------"
if [ "$fail" -eq 0 ]; then echo "SWEEP PASSED"; else echo "SWEEP FAILED"; exit 1; fi
