#!/usr/bin/env bash
# Elaborate the RTL at three distinct parameter sets to prove the design is
# genuinely parameterized (array dimension, operand width and KMAX all vary).
# Uses Icarus with -P top-level parameter overrides; no simulation is run.
set -euo pipefail
cd "$(dirname "$0")/.."

IVERILOG=${IVERILOG:-iverilog}
RTL=(rtl/*.v)

# name       N  DATA ACC KMAX
SETS=(
  "small      4   8  32  32"
  "default    8   8  32  64"
  "wide       8   8  48  64"
)

fail=0
for s in "${SETS[@]}"; do
  read -r name Nn D A K <<< "$s"
  printf '== %-8s N=%s DATA=%s ACC=%s KMAX=%s ... ' "$name" "$Nn" "$D" "$A" "$K"
  if $IVERILOG -g2012 -Wall -o /dev/null -s gemm_top \
       -Pgemm_top.N="$Nn" \
       -Pgemm_top.DATA_WIDTH="$D" \
       -Pgemm_top.ACC_WIDTH="$A" \
       -Pgemm_top.KMAX="$K" \
       "${RTL[@]}" 2> "/tmp/elab_gemm_$name.err"; then
    echo "OK"
  else
    echo "FAILED"; cat "/tmp/elab_gemm_$name.err"; fail=1
  fi
done
exit $fail
