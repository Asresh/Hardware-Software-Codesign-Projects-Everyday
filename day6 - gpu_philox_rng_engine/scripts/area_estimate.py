#!/usr/bin/env python3
"""Analytical area/flop estimate for the Philox RNG engine.

Yosys is not installed in this environment, so instead of a synthesized cell
report this prints a first-order structural estimate derived from the
parameters: the SIMD lane pipelines (each ROUNDS stages of two 32x32 multipliers
plus the XOR permutation), the context delay line, and the sequencer / mailbox
state. It is an estimate, labelled as such; it is not a synthesis result."""
import argparse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lanes", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=10)
    ap.add_argument("--addr-width", type=int, default=20)
    a = ap.parse_args()

    L, R, AW = a.lanes, a.rounds, a.addr_width

    # --- lane pipeline: R stages, each 128-bit counter reg + a valid bit ---
    lane_ff = L * R * (128 + 1)
    # --- two 32x32 multipliers per round stage; ~ (32*32) partial-product cells,
    #     ~6 gates each amortised ---
    mult_gates = L * R * 2 * (32 * 32) * 6 // 10
    # --- XOR permutation + key adds per round stage: ~ 4*32-bit ops ---
    perm_gates = L * R * (4 * 32) * 3

    # --- context delay line: R stages of {valid, addr, lane mask} ---
    ctx_ff = R * (1 + AW + L)

    # --- sequencer: base counter, counters, address, cycle counter ---
    seq_ff = 128 + 5 * 32 + AW
    seq_gates = 128 * 4 + 900          # 128-bit carry chains + FSM

    # --- CSR / mailbox: ~11 32-bit words + status/irq ---
    csr_ff = 11 * 32 + 8

    total_ff = lane_ff + ctx_ff + seq_ff + csr_ff
    total_gates = mult_gates + perm_gates + seq_gates + total_ff * 5

    print("Analytical area estimate (NOT a synthesis result; Yosys absent)")
    print("-------------------------------------------------------------")
    print(f"  parameters      : LANES={L}  ROUNDS={R}  ADDR_WIDTH={AW}")
    print(f"  lane pipeline FF: {lane_ff:6d}  ({L} lanes x {R} stages x 129b)")
    print(f"  context line FF : {ctx_ff:6d}")
    print(f"  sequencer FF    : {seq_ff:6d}")
    print(f"  CSR / mailbox FF: {csr_ff:6d}")
    print(f"  flip-flops (est): {total_ff:6d}")
    print(f"  multiplier gates: {mult_gates:6d}  ({L*R*2} x 32x32 multipliers)")
    print(f"  logic gates (est): {total_gates:6d}")
    print("  critical path   : one Philox round = 32x32 multiply -> XOR permute")
    print("                    (registered every round; fmax set by one multiply)")


if __name__ == "__main__":
    main()
