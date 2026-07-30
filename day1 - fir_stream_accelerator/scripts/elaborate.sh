#!/usr/bin/env bash
# Elaborate the RTL at three distinct parameter sets to prove the design is
# genuinely parameterized (width, tap count and FIFO depth all vary). Uses
# Icarus with -P top-level parameter overrides; no simulation is run.
set -euo pipefail
cd "$(dirname "$0")/.."

IVERILOG=${IVERILOG:-iverilog}
RTL=(rtl/*.v)

# name        DATA COEF TAPS DEPTH
SETS=(
  "small       8   8   4    8"
  "default    16  16   8   16"
  "wide       24  18  16   32"
)

fail=0
for s in "${SETS[@]}"; do
  read -r name D C T F <<< "$s"
  printf '== %-8s DATA=%s COEF=%s TAPS=%s FIFO_DEPTH=%s ... ' "$name" "$D" "$C" "$T" "$F"
  if $IVERILOG -g2012 -Wall -o /dev/null -s fir_accel_top \
       -Pfir_accel_top.DATA_WIDTH="$D" \
       -Pfir_accel_top.COEF_WIDTH="$C" \
       -Pfir_accel_top.TAPS="$T" \
       -Pfir_accel_top.FIFO_DEPTH="$F" \
       "${RTL[@]}" 2> /tmp/elab_$name.err; then
    echo "OK"
  else
    echo "FAILED"; cat /tmp/elab_$name.err; fail=1
  fi
done
exit $fail
