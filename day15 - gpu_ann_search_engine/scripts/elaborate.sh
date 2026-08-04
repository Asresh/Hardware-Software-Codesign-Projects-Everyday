#!/usr/bin/env bash
# Elaborate the ANN engine at three distinct parameter sets to prove the RTL is
# genuinely parameterized (differential correctness at each is checked by the
# testbench when run with matching -DANN_* software defines).
set -e
cd "$(dirname "$0")/.."
mkdir -p results

run() {
  local D=$1 P=$2 K=$3
  echo "== elaborate D=$D P=$P K=$K =="
  iverilog -g2012 -o "results/elab_${D}_${P}_${K}.vvp" -s ann_search_top -Irtl \
      -Pann_search_top.D=$D -Pann_search_top.P=$P -Pann_search_top.K=$K \
      rtl/*.v
  echo "   ok -> results/elab_${D}_${P}_${K}.vvp"
}

run 64 8 8
run 32 4 4
run 128 16 16
echo "all parameter sets elaborated cleanly"
