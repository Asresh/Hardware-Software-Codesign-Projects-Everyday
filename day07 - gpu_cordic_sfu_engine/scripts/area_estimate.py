#!/usr/bin/env python3
"""Analytical area/flop estimate for the CORDIC SFU engine.

Yosys is not installed in this environment, so instead of a synthesized cell
report this prints a first-order structural estimate derived from the
parameters: the SIMD CORDIC lanes (each a 40-bit x/y/z datapath with two barrel
shifters and three adders, plus the schedule ROM), the per-lane decode
pre-scale multiplier, and the sequencer / mailbox state. It is an estimate,
labelled as such; it is not a synthesis result."""
import argparse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lanes", type=int, default=4)
    ap.add_argument("--workw", type=int, default=40)
    ap.add_argument("--nrom", type=int, default=57)
    ap.add_argument("--addr-width", type=int, default=20)
    a = ap.parse_args()

    L, W, NROM, AW = a.lanes, a.workw, a.nrom, a.addr_width

    # --- per lane: x, y, z working regs + step/mode/base state ---
    lane_ff = L * (3 * W + 8 + 8 + 8 + 4)
    # --- per lane datapath: 2 barrel shifters (~W*log2(W) muxes) + 3 adders ---
    shift_gates = L * 2 * (W * 6) * 3
    add_gates   = L * 3 * W * 6
    # --- per lane schedule ROM: NROM x 64b (shared angle/shift table) ---
    rom_gates = L * NROM * 40 * 2
    # --- per lane decode: two 32x32 constant-ish multipliers (pre-scale) ---
    mult_gates = L * 2 * (32 * 32) * 6 // 10

    # --- sequencer: descriptor regs, wbase, cyc, per-lane latches ---
    seq_ff = 6 * 32 + 32 + 32 + L * (5 * 32) + L
    seq_gates = L * 32 * 3 + 1200          # address adders + FSM

    # --- CSR / mailbox: ~9 32-bit words + status/irq ---
    csr_ff = 9 * 32 + 8

    total_ff = lane_ff + seq_ff + csr_ff
    total_gates = shift_gates + add_gates + rom_gates + mult_gates \
        + seq_gates + total_ff * 5

    print("Analytical area estimate (NOT a synthesis result; Yosys absent)")
    print("-------------------------------------------------------------")
    print(f"  parameters      : LANES={L}  WORKW={W}  NROM={NROM}  ADDR_WIDTH={AW}")
    print(f"  lane datapath FF: {lane_ff:6d}  ({L} lanes x (3x{W}b xyz + state))")
    print(f"  sequencer FF    : {seq_ff:6d}")
    print(f"  CSR / mailbox FF: {csr_ff:6d}")
    print(f"  flip-flops (est): {total_ff:6d}")
    print(f"  shifter gates   : {shift_gates:6d}  ({L*2} barrel shifters)")
    print(f"  adder gates     : {add_gates:6d}  ({L*3} {W}-bit adders)")
    print(f"  ROM gates (est) : {rom_gates:6d}  ({L} x {NROM}-entry schedule)")
    print(f"  pre-scale mults : {mult_gates:6d}  ({L*2} x 32x32 multipliers)")
    print(f"  logic gates (est): {total_gates:6d}")
    print("  critical path   : one CORDIC micro-rotation = barrel shift -> add")
    print("                    (registered every step; no multiply in the loop)")


if __name__ == "__main__":
    main()
