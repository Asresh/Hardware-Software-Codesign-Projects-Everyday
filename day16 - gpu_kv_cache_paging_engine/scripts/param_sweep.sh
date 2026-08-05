#!/usr/bin/env bash
# Full differential simulation at several translation-cache geometries.  The
# golden model and the RTL are both re-parameterized, so each sweep point is a
# real correctness run (not just an elaboration check): the workload, the LRU
# replacement decisions and every physical block number change with the geometry.
set -e
cd "$(dirname "$0")/.."
mkdir -p results

run() {
  local SETS=$1 WAYS=$2 DEPTH=$3
  local dir="results/sweep_${SETS}x${WAYS}_${DEPTH}"
  echo "== SETS=$SETS WAYS=$WAYS FREE_DEPTH=$DEPTH =="
  mkdir -p "$dir"
  cc -std=c11 -O2 -Wall -Wextra \
     -DKVP_SETS=$SETS -DKVP_WAYS=$WAYS -DKVP_FREE_DEPTH=$DEPTH \
     -o "$dir/kvp_host" sw/kvp_host.c sw/kvp_model.c sw/kvp_baseline.c
  ./"$dir/kvp_host" --outdir "$dir" > /dev/null
  iverilog -g2012 -o "$dir/sim.vvp" -s kvp_tb -Irtl -I"$dir" rtl/*.v tb/kvp_tb.sv
  ( cd "$dir" && vvp sim.vvp > sim.log )
  if ! grep -q "TEST PASSED" "$dir/sim.log"; then
    echo "   FAILED - see $dir/sim.log"; exit 1
  fi
  grep -E "^TEST|^MET (checks|mismatches|fullrate_cycles|peak_batch_cycles)" "$dir/sim.log" \
    | sed 's/^/   /'
}

run 16 4 512
run 8  2 256
run 32 8 512
run 4  4 64
echo "all parameter sets pass differential simulation"
