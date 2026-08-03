#!/usr/bin/env bash
# Elaborate the RTL at three distinct (R,P) sets to prove the design is
# genuinely parameterized (compiles clean at each).
set -e
cd "$(dirname "$0")/.."
mkdir -p results
elab() {
  echo "== elaborate R=$1 P=$2 =="
  iverilog -g2012 -s arc_collective_top \
    -Parc_collective_top.R=$1 -Parc_collective_top.P=$2 \
    -o results/elab_${1}x${2}.vvp rtl/*.v
  echo "   ok -> results/elab_${1}x${2}.vvp"
}
elab 2 4
elab 4 4
elab 8 8
echo "all parameter sets elaborated"
