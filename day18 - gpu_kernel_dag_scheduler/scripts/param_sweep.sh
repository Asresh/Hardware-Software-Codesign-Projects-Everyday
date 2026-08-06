#!/usr/bin/env bash
# Full differential simulation at several geometries. Each point regenerates the
# vectors and the golden model for that geometry and runs the whole testbench -
# this is not an elaboration check, it is the complete comparison repeated.
set -u
cd "$(dirname "$0")/.."

GEOM=("64 4" "32 2" "32 8" "128 4")
fail=0

for g in "${GEOM[@]}"; do
    set -- $g
    N=$1; D=$2
    tag="sweep_${N}x${D}"
    echo "=============================================================="
    echo " geometry: MAX_NODES=$N  DEVICES=$D"
    echo "=============================================================="
    make -s clean >/dev/null 2>&1
    if make -s sim NODES="$N" DEVS="$D" > "results/${tag}.log" 2>&1; then
        chk=$(grep -E "^ checks" "results/${tag}.log" | tr -dc '0-9')
        mis=$(grep -E "^ mismatches" "results/${tag}.log" | tr -dc '0-9')
        echo "  PASSED  checks=${chk}  mismatches=${mis}"
    else
        echo "  FAILED - see results/${tag}.log"
        tail -20 "results/${tag}.log"
        fail=1
    fi
done

make -s clean >/dev/null 2>&1
echo "=============================================================="
if [ "$fail" -eq 0 ]; then
    echo " sweep: all geometries passed"
else
    echo " sweep: FAILURES present"
    exit 1
fi
