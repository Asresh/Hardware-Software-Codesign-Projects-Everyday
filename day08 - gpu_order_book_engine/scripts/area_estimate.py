#!/usr/bin/env python3
"""Analytical area estimate for the order-book engine.

Yosys is not installed in this environment, so this prints a first-order
flip-flop and combinational-cell estimate derived from the parameters. It is a
model (documented in the README), not a synthesis result."""
import argparse, math


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pw", type=int, default=16)
    ap.add_argument("--qw", type=int, default=24)
    ap.add_argument("--levels", type=int, default=32)
    a = ap.parse_args()
    PW, QW, N = a.pw, a.qw, a.levels
    logN = max(1, math.ceil(math.log2(N)))

    # ---- sequential (flip-flops) ----
    per_level = 1 + 1 + PW + QW          # valid + side + price + qty
    cam_ff    = N * per_level
    bbo_ff    = 2 * (1 + PW + QW)         # latched bid + ask snapshot
    misc_ff   = 32 + 1 + 1 + 1 + 1        # msg_count + upd_d1 + irq + overflow + irq_en
    ff        = cam_ff + bbo_ff + misc_ff

    # ---- combinational (rough 2-input-gate equivalents) ----
    match  = N * (PW + 1) * 2            # per-level (side,price) comparators
    prienc = 2 * N * 2                   # first-hit + first-free priority encoders
    upd    = (QW + 1) * 4                # add / clamped-sub / set / clr datapath
    # two reduction trees: (N-1) comparator+mux nodes each, ~ (PW + width) gates
    tree   = 2 * (N - 1) * (PW + (1 + PW + QW))
    popcnt = N * 6                       # active-level counter adder chain
    comb   = match + prienc + upd + tree + popcnt

    print("Order-book engine - analytical area estimate")
    print(f"  parameters : PW={PW} QW={QW} N_LEVELS={N} (tree depth {logN})")
    print(f"  flip-flops : {ff}")
    print(f"      CAM levels        {cam_ff:6d}  ({N} x {per_level}b)")
    print(f"      BBO snapshot      {bbo_ff:6d}")
    print(f"      control/counters  {misc_ff:6d}")
    print(f"  comb 2-in gates (approx): {comb}")
    print(f"      match compare     {match:6d}")
    print(f"      priority encoders {prienc:6d}")
    print(f"      update datapath   {upd:6d}")
    print(f"      2x reduction tree {tree:6d}")
    print(f"      active popcount   {popcnt:6d}")
    print("  critical path: registered CAM array -> comparator match/alloc "
          "(single cycle); BBO reduction is a separate pipeline stage of "
          f"depth ~{logN} comparators.")


if __name__ == "__main__":
    main()
