#!/usr/bin/env python3
"""Analytical area estimate, used when Yosys is not installed.

This counts state, not gates: registers are exact (they are enumerated from the
RTL declarations), and the combinational figures are rough. It is here so the
storage cost of the design scales visibly with MTU, queue-pair count and
receive-buffer count, which is the interesting part - the packet buffer pool
dominates everything else.
"""
import argparse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mtu", type=int, default=16)
    ap.add_argument("--qp", type=int, default=4)
    ap.add_argument("--bufs", type=int, default=4)
    a = ap.parse_args()

    rows = []

    # receive packet buffer pool - the dominant term
    pool = a.bufs * a.mtu * 32
    rows.append(("rx packet buffer pool", f"{a.bufs} x {a.mtu} x 32b", pool))

    # per-slot metadata: dst(32) len(8) flags(4) qp(4) seq(8) tag(8)
    md = a.bufs * (32 + 8 + 4 + 4 + 8 + 8)
    rows.append(("rx slot metadata", f"{a.bufs} x 64b", md))

    # per queue pair: tx sequence, rx expected sequence, credits, pending
    # returns, running message byte count
    per_qp = 8 + 8 + 5 + 5 + 32
    rows.append(("per queue-pair state", f"{a.qp} x {per_qp}b", a.qp * per_qp))

    rows.append(("tx payload staging FIFO", "8 x 32b", 8 * 32))
    rows.append(("rx accumulate result FIFO", "8 x 32b", 8 * 32))
    rows.append(("work-queue entry register", "8 x 32b", 8 * 32))
    rows.append(("read arbiter tag FIFO", "8 x 2b", 8 * 2))
    rows.append(("control/status registers", "24 x 32b", 24 * 32))
    rows.append(("tx datapath registers", "src/dst/rem/len/idx", 32 * 3 + 40))
    rows.append(("rx datapath registers", "dst/len/idx/cqe", 32 * 2 + 48))

    total = sum(r[2] for r in rows)

    print("Analytical area estimate (Yosys not present)")
    print(f"  MTU_WORDS={a.mtu}  NUM_QP={a.qp}  RX_BUFS={a.bufs}")
    print("")
    print(f"  {'block':<28} {'shape':<22} {'flops':>7}")
    print("  " + "-" * 59)
    for name, shape, bits in rows:
        print(f"  {name:<28} {shape:<22} {bits:>7}")
    print("  " + "-" * 59)
    print(f"  {'total sequential state':<28} {'':<22} {total:>7} bits")
    print("")
    print("  Combinational: one 32-bit adder in the accumulate fold, one")
    print("  32-bit adder per address generator (4), a 3-way round-robin")
    print("  arbiter, a NUM_QP-wide priority encoder for credit return, and")
    print("  the header pack/unpack, which is wiring. No multipliers.")
    print("")
    print(f"  The buffer pool is {100.0*pool/total:.0f}% of the state, and it")
    print("  scales as RX_BUFS x MTU_WORDS - which is the flow-control")
    print("  trade-off made explicit: more credits means more silicon.")


if __name__ == "__main__":
    main()
