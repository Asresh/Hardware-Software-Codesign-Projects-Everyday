#!/usr/bin/env python3
"""Analytical area estimate for kds_top.

Yosys is not installed in this environment, so `make synth` falls back to this:
a flip-flop and gate count derived by hand from the RTL, parameter by parameter.
It is an estimate of the *storage and compare* structure, which is what dominates
this design - the scoreboard is a CAM, and its cost is quadratic in the node
count while everything else is linear.
"""
import argparse
import math


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nodes", type=int, default=64)
    ap.add_argument("--devices", type=int, default=4)
    a = ap.parse_args()

    N, D = a.nodes, a.devices
    nidw = max(1, math.ceil(math.log2(N)))
    didw = max(1, math.ceil(math.log2(D)))
    depw = (N + 31) // 32

    ff = {}
    # kds_node_mem: dependency masks dominate
    ff["node_mem.dep"] = N * N
    ff["node_mem.dev"] = N * D
    ff["node_mem.dur"] = N * 16
    ff["node_mem.kid"] = N * 32
    # kds_core scheduling state
    ff["core.done+issued"] = 2 * N
    ff["core.start_t"] = N * 32
    ff["core.finish_t"] = N * 32
    ff["core.dev_of"] = N * didw
    ff["core.seq_of"] = N * 16
    ff["core.dep_acc"] = N
    ff["core.valid_mask"] = N
    ff["core.counters"] = 9 * 32 + D * 32
    ff["core.fetch/wb ptrs"] = 4 * 16 + 2 * nidw + 16
    ff["core.misc"] = 3 + 4 + 32 + 16 + 64
    # kds_devq
    ff["devq"] = D * (1 + 16 + nidw)
    # kds_regfile
    ff["regfile"] = 3 * 32 + 4 + 32
    # kds_axil_master
    ff["axil_master"] = 3

    gates = {}
    # the associative match: per node, an N-bit AND-NOT plus an N-input OR tree
    gates["scoreboard match"] = N * (N + N)
    # placer: per node an affinity AND + OR over devices, then the two-level
    # priority encoder, then the device encoder
    gates["placer affinity"] = N * (2 * D)
    gates["placer prio enc"] = N + 2 * (N // 8 + 1) * 8
    gates["devq countdown"] = D * 16 * 5
    gates["retire mask decode"] = D * N
    gates["writeback mux"] = 4 * 32 * 3
    gates["regfile read mux"] = (17 + D) * 32

    tff = sum(ff.values())
    tg = sum(gates.values())

    print(f"kds_top analytical area estimate  (MAX_NODES={N}, DEVICES={D})")
    print(f"  derived widths: NIDW={nidw}, DIDW={didw}, DEPW={depw}, "
          f"NODE_WORDS={depw+2}")
    print()
    print("  flip-flops")
    for k, v in ff.items():
        print(f"    {k:<24s} {v:>8d}")
    print(f"    {'total':<24s} {tff:>8d}")
    print()
    print("  combinational gate equivalents")
    for k, v in gates.items():
        print(f"    {k:<24s} {v:>8d}")
    print(f"    {'total':<24s} {tg:>8d}")
    print()
    print(f"  scoreboard share of storage: "
          f"{100.0*ff['node_mem.dep']/tff:.1f}% of flip-flops")
    print(f"  the dependency CAM is O(N^2) = {N*N} bits; every other structure "
          f"is O(N) or O(DEVICES)")
    print()
    print("  critical path (levels of logic, RUN phase):")
    print("    done_mask -> AND-NOT -> OR tree (log2 N = "
          f"{math.ceil(math.log2(max(2,N)))}) -> affinity AND -> group OR ->")
    print("    two-level priority encode -> device encode -> devq load enable")


if __name__ == "__main__":
    main()
