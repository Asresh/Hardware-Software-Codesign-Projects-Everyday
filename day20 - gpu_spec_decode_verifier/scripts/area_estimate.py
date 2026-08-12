#!/usr/bin/env python3
"""Analytical area estimate for the draft-tree verifier.

Yosys is not installed on the machine this was developed on, so `make synth`
falls back to this: a flop and comparator count derived from the RTL by hand,
parameterised the same way the RTL is. It is an estimate of the *storage and
compare structure*, not a synthesis result, and it is labelled as such in the
README - no gate count from this script is quoted as a measured number.

The interesting line is the last one. The node array is held in flops rather
than a RAM because every node has to be interrogated on every step of the walk,
and that decision is what the area is spent on: N x 16 comparators for the
parent match, N x 32 for the token match, N x 16 for the score threshold, and a
log2(N)-level argmax tree over them. A RAM-backed version would be a fraction
of the area and would take N cycles per path step instead of one.
"""
import argparse
import math


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nodes", type=int, default=64)
    ap.add_argument("--depth", type=int, default=16)
    a = ap.parse_args()

    n, d = a.nodes, a.depth
    iw = max(1, math.ceil(math.log2(n)))
    dw = max(1, math.ceil(math.log2(d + 1)))
    levels = math.ceil(math.log2(n))

    # ---- flops -------------------------------------------------------------
    node_bits = 16 + 32 + 32 + 16 + 16          # par, tok, pred, score, thr
    arr = n * node_bits
    fifo_depth = 1 << max(2, math.ceil(math.log2(d + 2)))
    fifo = fifo_depth * 129 + 2 * (math.ceil(math.log2(fifo_depth)) + 1)
    csr = 32 * 9 + 3 + 3 + 32 * 10 + 32 * d     # cfg + irq + err + stats + hist
    fsm = 3 + 17 + 1 + 2 + 16 * 2 + dw + iw + dw + 3 + 32 + 3

    flops = arr + fifo + csr + fsm

    # ---- combinational structure ------------------------------------------
    cmp_parent = n * 16
    cmp_token = n * 32
    cmp_score = n * 16
    cmp_valid = n * 16                          # live / bad-parent range check
    tree = (n - 1) * (16 + iw + 1)              # merge cells in the argmax tree
    mult = 16 * 16                              # one load-time Q0.16 multiply
    mux = n * (32 + 16 + 32 + 16)               # broadcast read of the current node

    print("analytical area estimate (not a synthesis result)")
    print("  MAX_NODES = %d, MAX_DEPTH = %d, index width = %d, "
          "argmax tree levels = %d" % (n, d, iw, levels))
    print("")
    print("  flip-flops")
    print("    node array      %6d  (%d nodes x %d bits: par/tok/pred/score/thr)"
          % (arr, n, node_bits))
    print("    result FIFO     %6d  (%d x 129 + pointers)" % (fifo, fifo_depth))
    print("    CSR + histogram %6d  (%d histogram counters)" % (csr, d))
    print("    walk FSM        %6d" % fsm)
    print("    total           %6d" % flops)
    print("")
    print("  combinational (equivalent 1-bit compare / select cells)")
    print("    parent match    %6d  (%d x 16)" % (cmp_parent, n))
    print("    token match     %6d  (%d x 32)" % (cmp_token, n))
    print("    score threshold %6d  (%d x 16)" % (cmp_score, n))
    print("    liveness/range  %6d  (%d x 16)" % (cmp_valid, n))
    print("    argmax tree     %6d  (%d merge cells, %d levels)"
          % (tree, n - 1, levels))
    print("    broadcast mux   %6d" % mux)
    print("    threshold mult  %6d  (one 16x16, load time only)" % mult)
    print("")
    print("  critical path, walk step: broadcast mux -> parent/token/score "
          "compare -> %d-level argmax tree -> index register" % levels)
    print("  a RAM-backed node store would save ~%d flops and cost %d cycles "
          "per path step instead of 1" % (arr, n))


if __name__ == "__main__":
    main()
