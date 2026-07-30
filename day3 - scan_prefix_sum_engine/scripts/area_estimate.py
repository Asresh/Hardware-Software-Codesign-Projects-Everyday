#!/usr/bin/env python3
"""Analytical area/flop estimate for the scan engine.

Yosys is not installed in this environment, so instead of a synthesized cell
report this prints a first-order structural estimate derived directly from the
parameters: the parallel-prefix adder tree, the pipeline/carry registers, the
descriptor CSR/controller state, and the wide datapath registers. It is an
estimate, labelled as such; it is not a synthesis result."""
import argparse
import math


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lanes", type=int, default=16)
    ap.add_argument("--width", type=int, default=32)
    ap.add_argument("--addr-width", type=int, default=20)
    ap.add_argument("--len-width", type=int, default=20)
    a = ap.parse_args()

    L, W = a.lanes, a.width
    levels = math.ceil(math.log2(L))

    # --- combinational adders ---
    # Hillis-Steele inclusive scan: (L - 2^d) adders at level d, summed over levels.
    tree_adders = sum(L - (1 << d) for d in range(levels))
    # exclusive subtract per lane + carry add per lane
    excl_adders = L
    carry_adders = L
    total_adders = tree_adders + excl_adders + carry_adders
    add_gates = total_adders * W * 9          # ~9 gates/bit ripple-add estimate

    # --- registers (flip-flops) ---
    ff = 0
    ff += W                                   # running carry
    ff += L * W                               # datapath output beat
    ff += 8                                   # datapath valid/lane bookkeeping
    ff += 2 * a.addr_width + a.len_width      # src/dst/len descriptor regs
    ff += 32                                  # cycle counter
    ff += 3 * (a.addr_width + 1)              # nbeats/rd_idx/wr_idx
    ff += a.len_width                         # r1 / control
    ff += 32                                  # CSR misc (mode, irq, status shadow)
    reg_gates = ff * 6                        # ~6 gates/flop

    total_gates = add_gates + reg_gates

    print("Analytical area estimate (Yosys not present) - scan_top")
    print("-------------------------------------------------------")
    print(f"  parameters      : LANES={L} W={W} "
          f"ADDR_WIDTH={a.addr_width} LEN_WIDTH={a.len_width}")
    print(f"  prefix levels   : {levels}  (ceil(log2(LANES)) adder depth)")
    print(f"  tree adders     : {tree_adders} x {W}-bit")
    print(f"  excl+carry adds : {excl_adders + carry_adders} x {W}-bit")
    print(f"  total adders    : {total_adders} x {W}-bit")
    print(f"  flip-flops      : ~{ff}")
    print(f"  est. adder gates: ~{add_gates}")
    print(f"  est. reg gates  : ~{reg_gates}")
    print(f"  est. total gates: ~{total_gates}  (~{total_gates/1000:.1f}k)")
    print("  critical path   : APB CSR read mux, or the "
          f"{levels}-level ({levels} x {W}-bit adds) prefix tree + carry add")


if __name__ == "__main__":
    main()
