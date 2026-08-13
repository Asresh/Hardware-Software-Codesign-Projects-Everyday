#!/usr/bin/env python3
"""Analytical area/flop estimate for the bitonic sort engine.

Yosys is not installed in this environment, so instead of a synthesized cell
report this prints a first-order structural estimate derived directly from the
parameters: the bitonic comparator network, its pipeline registers, the
descriptor CSR/controller state, and the wide datapath. It is an estimate,
labelled as such; it is not a synthesis result."""
import argparse
import math


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=16)
    ap.add_argument("--width", type=int, default=32)
    ap.add_argument("--addr-width", type=int, default=20)
    ap.add_argument("--tile-width", type=int, default=16)
    a = ap.parse_args()

    N, W = a.n, a.width
    logn = int(math.ceil(math.log2(N)))
    nstages = logn * (logn + 1) // 2

    # --- comparators: N/2 compare-exchange cells per stage ---
    cae = (N // 2) * nstages
    # each CAE: one W-bit comparator (~5 gates/bit) + two W-bit 2:1 muxes (~3/bit)
    cae_gates = cae * W * (5 + 3 + 3)

    # --- pipeline registers: (nstages+1) rows of N W-bit keys ---
    pipe_ff = (nstages + 1) * N * W
    pipe_ff += (nstages + 1) * 2          # valid + direction shift registers

    # --- controller + CSR flops ---
    ctrl_ff = 0
    ctrl_ff += 2 * a.addr_width           # src/dst descriptor regs
    ctrl_ff += a.tile_width               # ntiles reg
    ctrl_ff += 2 * (a.tile_width + 1)     # rd_idx / wr_idx
    ctrl_ff += 32                         # cycle counter
    ctrl_ff += 16                         # state / valid / irq / mode bookkeeping

    ff = pipe_ff + ctrl_ff
    reg_gates = ff * 6                     # ~6 gates/flop
    total_gates = cae_gates + reg_gates

    print("Analytical area estimate (Yosys not present) - sort_top")
    print("-------------------------------------------------------")
    print(f"  parameters       : N={N} W={W} "
          f"ADDR_WIDTH={a.addr_width} TILE_WIDTH={a.tile_width}")
    print(f"  comparator stages: {nstages}  (LOGN*(LOGN+1)/2, LOGN={logn})")
    print(f"  compare-exchange : {cae} cells x {W}-bit ({N//2}/stage)")
    print(f"  pipeline depth   : {nstages + 1} cycles (latency)")
    print(f"  flip-flops       : ~{ff}  ({pipe_ff} pipeline + {ctrl_ff} control)")
    print(f"  est. CAE gates   : ~{cae_gates}")
    print(f"  est. reg gates   : ~{reg_gates}")
    print(f"  est. total gates : ~{total_gates}  (~{total_gates/1000:.1f}k)")
    print(f"  critical path    : one compare-exchange stage "
          f"(a {W}-bit compare + a {W}-bit mux) between pipeline registers")


if __name__ == "__main__":
    main()
