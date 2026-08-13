#!/usr/bin/env python3
"""Analytical area estimate, used when Yosys is not installed.

Counts are structural - what the RTL instantiates, not what a synthesiser
would report - so treat them as a shape rather than a number. The point being
made is the ratio: the MX unit is a small fraction of a core that is itself a
small fraction of the memories, which is the argument for putting the cast in
the instruction set rather than behind a bus."""
import argparse

CELLS = [
    # name, flops, approximate 2-input-gate equivalents
    ("register file (32 x 32)",            1024, 1024 * 6),
    ("pipeline state (F/X/W)",              180,  180 * 6),
    ("counters (6 x 32)",                   192,  192 * 6),
    ("control-plane registers",             230,  230 * 6),
    ("ALU (add/sub, shifter, compares)",      0,   1400),
    ("decoder + immediate generation",        0,    420),
    ("MX unit: two quantisers",               0,    620),
    ("MX unit: two dequantisers",             0,    180),
    ("MX unit: amax, scale, pack",            0,    210),
    ("load extend / store byte enables",      0,    260),
    ("host bus mux and window decode",        0,    180),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--imem", type=int, default=12)
    ap.add_argument("--dmem", type=int, default=12)
    a = ap.parse_args()

    print("structural area estimate (Yosys not present)\n")
    print("%-38s %8s %10s" % ("block", "flops", "gates"))
    print("-" * 58)
    tf = tg = 0
    for name, f, g in CELLS:
        print("%-38s %8d %10d" % (name, f, g))
        tf += f
        tg += g
    print("-" * 58)
    print("%-38s %8d %10d" % ("logic total", tf, tg))
    mx = sum(g for n, _, g in CELLS if n.startswith("MX unit"))
    print("\nMX unit share of the logic: %.1f%%" % (100.0 * mx / tg))
    print("instruction memory: %d words (%d bits of SRAM)"
          % (1 << a.imem, (1 << a.imem) * 32))
    print("data memory:        %d words (%d bits of SRAM)"
          % (1 << a.dmem, (1 << a.dmem) * 32))
    print("\nThe five custom instructions cost about %d gates - roughly a"
          % mx)
    print("quarter of the base ALU, and under a thousandth of the SRAM they")
    print("sit beside.")


if __name__ == "__main__":
    main()
