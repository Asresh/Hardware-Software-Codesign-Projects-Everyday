#!/usr/bin/env bash
# Elaborate the RTL at three distinct channel-index widths to prove the design
# is genuinely parameterized (compiles clean at each).
set -e
cd "$(dirname "$0")/.."
mkdir -p results
for CHW in 4 8 10; do
  echo "== elaborate CHW=$CHW =="
  iverilog -g2012 -s crc_feed_integrity_engine \
    -Pcrc_feed_integrity_engine.CHW=$CHW \
    -o results/elab_chw${CHW}.vvp rtl/*.v
  echo "   ok -> results/elab_chw${CHW}.vvp"
done
echo "all parameter sets elaborated"
