#!/usr/bin/env python3
"""Analytical storage/flop estimate for the KV-cache paging engine.

Yosys is not installed in this environment, so `make synth` falls back to this
structural count: it walks the same geometry the RTL is parameterized by and
reports the state bits and the wide comparators that dominate the area.
"""
import argparse
import math


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", type=int, default=16)
    ap.add_argument("--ways", type=int, default=4)
    ap.add_argument("--seq-w", type=int, default=12)
    ap.add_argument("--log-w", type=int, default=16)
    ap.add_argument("--phys-w", type=int, default=24)
    ap.add_argument("--free-depth", type=int, default=512)
    a = ap.parse_args()

    key_w = a.seq_w + a.log_w
    set_bits = int(math.log2(a.sets))
    way_bits = max(1, math.ceil(math.log2(a.ways)))
    tag_w = key_w - set_bits
    entries = a.sets * a.ways

    tlb_bits = entries * (1 + tag_w + a.phys_w)
    ord_bits = a.sets * a.ways * way_bits
    pool_bits = a.free_depth * a.phys_w + math.ceil(math.log2(a.free_depth)) + 1
    core_bits = (32 * 3          # req_ptr / res_ptr / reqs_left
                 + 4 + a.seq_w + 32   # op / seq / seq_row
                 + 17 * 2 + 1    # idx / n_items / noalloc
                 + 32            # result_q
                 + a.phys_w * 2  # alloc_blk / freed_cnt
                 + 32 * 2        # cyc_cnt / last_cyc
                 + 32 * 8        # statistics + res_words
                 + 4)            # state
    csr_bits = 32 * 5 + 16 + 4

    print("KV-cache paging engine - analytical area estimate")
    print(f"  geometry              : {a.sets} sets x {a.ways} ways "
          f"({entries} entries), tag {tag_w}b, phys {a.phys_w}b")
    print(f"  translation cache     : {tlb_bits} bits "
          f"(valid+tag+phys) + {ord_bits} LRU order bits")
    print(f"  free-block pool       : {pool_bits} bits "
          f"({a.free_depth} x {a.phys_w}b + pointer)")
    print(f"  walker state + stats  : {core_bits} bits")
    print(f"  MMIO register file    : {csr_bits} bits")
    print(f"  total state           : "
          f"{tlb_bits + ord_bits + pool_bits + core_bits + csr_bits} bits")
    print(f"  parallel comparators  : {a.ways} x {tag_w}b tag compare "
          f"(one set, combinational probe)")
    print(f"                        : 1 x {a.seq_w}x16 multiplier "
          f"(seq * bt_stride, once per request word)")
    print("  critical path         : tag compare -> hit mux -> result word")
    print("  note: the pool and the cache map to block RAM / distributed RAM on")
    print("        an FPGA; only the LRU order vectors and the walker state need")
    print("        flops.")


if __name__ == "__main__":
    main()
