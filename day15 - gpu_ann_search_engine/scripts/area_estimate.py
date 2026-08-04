#!/usr/bin/env python3
"""Analytical flop/area estimate for the ANN engine (Yosys is not installed in
this environment).  Counts the dominant registers so the README can quote a
scale figure without claiming a real synthesis run."""
import argparse

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--d", type=int, default=64)
    ap.add_argument("--p", type=int, default=8)
    ap.add_argument("--k", type=int, default=8)
    a = ap.parse_args()
    D, P, K = a.d, a.p, a.k

    query_ram = D * 8                      # int8 query bytes
    acc       = 32                         # score accumulator
    chunk_vid = (max(1, (D // P - 1).bit_length())) + 32
    topk      = K * (32 + 32 + 1)          # score + id + valid per slot
    csr       = 32 * 8                     # status/stat/ctrl registers
    flops = query_ram + acc + chunk_vid + topk + csr

    # combinational: P distance PEs (mul+sub) + adder tree + K comparators
    pe_mul   = P                           # int8 multipliers / squarers
    cmp      = K                           # top-K comparators
    add_tree = P - 1

    print(f"ANN engine analytical area estimate (D={D} P={P} K={K})")
    print(f"  registers (flops)      ~ {flops}")
    print(f"    query byte RAM       : {query_ram}")
    print(f"    score accumulator    : {acc}")
    print(f"    chunk/vector counters: {chunk_vid}")
    print(f"    top-{K} slots         : {topk}")
    print(f"    CSR/status           : {csr}")
    print(f"  combinational")
    print(f"    distance PEs (mul)   : {pe_mul}")
    print(f"    adder-tree adds      : {add_tree}")
    print(f"    top-K comparators    : {cmp}")
    print("  (install yosys for a gate-level count: make synth)")

if __name__ == "__main__":
    main()
