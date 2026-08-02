#!/usr/bin/env bash
# Elaborate the RTL at three distinct expert counts to prove the design is
# genuinely parameterized (compiles clean at each).
set -e
cd "$(dirname "$0")/.."
mkdir -p results
elab() {
  echo "== elaborate E=$1 K=$2 =="
  iverilog -g2012 -s moe_router_engine \
    -Pmoe_router_engine.E=$1 -Pmoe_router_engine.K=$2 \
    -o results/elab_${1}x${2}.vvp rtl/*.v
  echo "   ok -> results/elab_${1}x${2}.vvp"
}
elab 4  2
elab 8  2
elab 16 2
echo "all parameter sets elaborated"
