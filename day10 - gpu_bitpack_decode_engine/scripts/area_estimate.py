#!/usr/bin/env python3
# Analytical flop/LUT estimate (Yosys is not installed in this environment).
# Counts the dominant registers and combinational operators from the RTL
# structure so the README can quote an order-of-magnitude area without synth.
import argparse

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--lanes', type=int, default=4)
    ap.add_argument('--bufw',  type=int, default=192)
    ap.add_argument('--winw',  type=int, default=128)
    a = ap.parse_args()

    L, BUFW, WINW = a.lanes, a.bufw, a.winw

    ff = {
        'reader buf + count': BUFW + 9,
        'egress register (data+cnt+last+valid)': L*32 + 3 + 1 + 1,
        'carry / remaining / width / paybits': 32 + 16 + 6 + 21,
        'block/value/cycle counters': 32*3,
        'AXI4-Lite regfile (ctrl/status/errcode)': 32*3 + 8,
        'FSM state + strobes': 3 + 4,
    }
    lut = {
        'field extractor (L barrel shifters, WINW-wide)': L * WINW,
        'zig-zag + %d-wide prefix adder' % L: L * 32 * 2,
        'fit / take comparators': 8 * 9,
        'reader shift/merge mux (BUFW-wide)': BUFW * 2,
        'AXI4-Lite decode': 64,
    }
    tot_ff = sum(ff.values())
    tot_lut = sum(lut.values())
    print(f"Analytical area estimate (LANES={L}, BUFW={BUFW}, WINW={WINW})")
    print("-" * 56)
    print("Flip-flops:")
    for k, v in ff.items():
        print(f"  {k:<48} {v:>5}")
    print(f"  {'TOTAL FF':<48} {tot_ff:>5}")
    print("Combinational (approx 6-LUT equivalents):")
    for k, v in lut.items():
        print(f"  {k:<48} {v:>5}")
    print(f"  {'TOTAL LUT (approx)':<48} {tot_lut:>5}")
    print("-" * 56)
    print("Single-clock design; critical path = reader window -> barrel-shift")
    print("extract -> zig-zag -> 4-wide delta prefix -> egress register.")

if __name__ == '__main__':
    main()
