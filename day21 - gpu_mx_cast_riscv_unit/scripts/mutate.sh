#!/usr/bin/env bash
# Mutation check: a test suite that cannot fail proves nothing, so each of these
# injects one real defect into a copy of the RTL and demands that the testbench
# notices. Any mutant that still passes is a hole in the tests.
#
# The eight chosen here split evenly between the two halves of the design. Four
# are numeric - the round-to-even tie going the wrong way, the sticky bit being
# dropped so a value just above a midpoint rounds down, the shared scale off by
# one binade, and the amax forgetting its accumulator so only the last pair of
# elements counts. Four are microarchitectural - the writeback forward removed
# so a consumer reads a stale register, the instruction behind a taken branch
# not being killed, byte stores writing lane 0 regardless of address, and LB
# zero-extending. None is a syntax error, none changes an interface, and each
# produces a core that still runs every program to completion.
set -e
cd "$(dirname "$0")/.."

IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
VEC=tb/vectors

if [ ! -f "$VEC/mxq_const.vh" ]; then
    echo "run 'make vectors' first"; exit 1
fi

# name | file | sed expression
MUTANTS=(
  "rne_tie_parity|mxq_mx_unit.v|s/(us >  12'd64)/(us >= 12'd64)/"
  "sticky_ignored|mxq_mx_unit.v|s/us = u + {11'b0, sticky};/us = u;/"
  "scale_off_by_one|mxq_mx_unit.v|s/shared_scale = ea - \`MXQ_EMAX_ELEM;/shared_scale = ea - 8'd1;/"
  "amax_drops_accumulator|mxq_mx_unit.v|s/(m_ab > m_in) ? m_ab : m_in/m_ab/"
  "no_writeback_forward|mxq_core.v|s/wire fwd1 = w_valid & w_we & (w_rd == rs1);/wire fwd1 = 1'b0;/"
  "branch_shadow_not_killed|mxq_core.v|s/valid_x <= valid_f \& ~redirect;/valid_x <= valid_f;/"
  "byte_store_enable|mxq_core.v|s/(4'b0001 << mem_addr\[1:0\])/(4'b0001)/"
  "load_zero_extends|mxq_core.v|s/{{24{bsel\[7\]}}/{{24{1'b0}}/"
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

    $IVERILOG -g2012 -o "$work/sim.vvp" -s mxq_tb \
        -I"$work/rtl" -I"$VEC" "$work"/rtl/*.v tb/mxq_tb.sv 2>/dev/null
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
