#!/usr/bin/env bash
# Mutation check: a test suite that cannot fail proves nothing, so each of
# these injects one real defect into a copy of the RTL and demands that the
# testbench notices. Any mutant that still passes is a hole in the tests.
set -e
cd "$(dirname "$0")/.."

CC=${CC:-cc}
IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
VEC=tb/vectors

if [ ! -f "$VEC/p2p_const.vh" ]; then
    echo "run 'make vectors' first"; exit 1
fi

# name | file | sed expression
MUTANTS=(
  "no_last_flag|p2p_tx.v|s/(is_last ? \`P2P_FLAG_LAST  : 4'h0)/(is_last ? 4'h0 : 4'h0)/"
  "accum_becomes_write|p2p_rx.v|s/ds <= D_ACC;/ds <= D_WR;/"
  "wrong_error_priority|p2p_wqe_fetch.v|s/chk = \`P2P_ERR_ALIGN;/chk = \`P2P_ERR_RANGE;/"
  "arbiter_tag_tail|p2p_rd_arb.v|s/head = tag\[t_rd\]/head = tag[t_wr]/"
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

    $IVERILOG -g2012 -o "$work/sim.vvp" -s p2p_tb \
        -I"$work/rtl" -I"$VEC" "$work"/rtl/*.v tb/p2p_tb.sv 2>/dev/null
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
