#!/usr/bin/env bash
# Mutation check: a test suite that cannot fail proves nothing, so each of these
# injects one real defect into a copy of the RTL and demands that the testbench
# notices. Any mutant that still passes is a hole in the tests.
#
# The six chosen here are the mistakes this design is actually prone to: the
# argmax tie-break silently going to the wrong sibling, the two-term threshold
# taking the min instead of the max, the acceptance compare losing its equal
# case, the software cap not being clamped to the hardware depth, the error
# priority encode reordered, and the over-length detector off by exactly one
# beat.  None of them is a syntax error and none changes the interface; each one
# produces a plausible-looking accelerator that returns a different token.
set -e
cd "$(dirname "$0")/.."

CC=${CC:-cc}
IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
VEC=tb/vectors

if [ ! -f "$VEC/sdv_const.vh" ]; then
    echo "run 'make vectors' first"; exit 1
fi

# name | file | sed expression
MUTANTS=(
  "argmax_tie_to_high_index|sdv_argmax_tree.v|s/tk\[l-1\]\[b\] > tk\[l-1\]\[a\]/tk[l-1][b] >= tk[l-1][a]/"
  "threshold_takes_min|sdv_node_array.v|s/(rel_q > th_abs)/(rel_q < th_abs)/"
  "score_compare_strict|sdv_node_array.v|s/score\[j\] >= cur_thr/score[j] > cur_thr/"
  "cap_not_clamped_to_depth|sdv_core.v|s/(cfg_max_acc > D) ? D\[DW-1:0\]/(1'b0) ? D[DW-1:0]/"
  "error_priority_reordered|sdv_core.v|s/e_par              ? \`SDV_ERR_PARENT/e_self             ? \`SDV_ERR_SELF  /"
  "overflow_off_by_one|sdv_core.v|s/if (cnt >= N) ovf/if (cnt > N) ovf/"
)

pass=0
caught=0

for m in "${MUTANTS[@]}"; do
    name="${m%%|*}"; rest="${m#*|}"
    file="${rest%%|*}"; expr="${rest#*|}"

    work="results/mutant_$name"
    rm -rf "$work"; mkdir -p "$work/rtl"
    cp rtl/*.v rtl/*.vh "$work/rtl/"
    sed -i.bak "$expr" "$work/rtl/$file"
    if cmp -s "$work/rtl/$file" "$work/rtl/$file.bak"; then
        echo "MUTANT $name: pattern did not match - script is stale"
        exit 1
    fi
    rm -f "$work/rtl/"*.bak

    $IVERILOG -g2012 -o "$work/sim.vvp" -s sdv_tb \
        -I"$work/rtl" -I"$VEC" "$work"/rtl/*.v tb/sdv_tb.sv 2>/dev/null
    ( cd "$VEC" && $VVP "../../$work/sim.vvp" > "../../$work/sim.log" 2>&1 ) || true

    if grep -q "TEST PASSED" "$work/sim.log"; then
        echo "MUTANT $name: SURVIVED - the tests do not cover this"
        pass=$((pass + 1))
    else
        n=$(grep -c "^MISMATCH" "$work/sim.log" || true)
        echo "MUTANT $name: caught ($n reported mismatches)"
        caught=$((caught + 1))
    fi
done

echo ""
echo "MUTATION caught=$caught survived=$pass"
[ "$pass" -eq 0 ] || exit 1
