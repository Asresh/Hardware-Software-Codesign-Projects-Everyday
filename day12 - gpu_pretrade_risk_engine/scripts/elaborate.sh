#!/usr/bin/env bash
# Elaborate the RTL at three distinct (SYM_N, ACCT_N) sizes to prove the design
# is genuinely parameterized (compiles clean at each).
set -e
cd "$(dirname "$0")/.."
mkdir -p results
elab() {
  echo "== elaborate SYM_N=$1 ACCT_N=$2 =="
  iverilog -g2012 -s pretrade_risk_engine \
    -Ppretrade_risk_engine.SYM_N=$1 -Ppretrade_risk_engine.ACCT_N=$2 \
    -o results/elab_${1}x${2}.vvp rtl/*.v
  echo "   ok -> results/elab_${1}x${2}.vvp"
}
elab 16 4
elab 32 8
elab 64 16
echo "all parameter sets elaborated"
