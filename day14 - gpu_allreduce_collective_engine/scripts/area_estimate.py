#!/usr/bin/env python3
"""Analytical flop/LUT area estimate for the all-reduce collective engine.
Used when Yosys is unavailable. Rough, transparent, clearly an estimate."""
import argparse

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--r", type=int, default=4)
    ap.add_argument("--p", type=int, default=4)
    args = ap.parse_args()
    R, P, DW, AW = args.r, args.p, 32, 24

    # ---- flops ----
    # systolic array: skew shift regs + stage partials + valid pipe
    skew   = (R * (R - 1) // 2) * P * DW        # rank r delayed by r cycles
    part   = R * P * DW                          # R stage partials
    vpipe  = R                                   # valid pipeline
    wpipe  = R * (AW + P)                         # write addr/mask delay pipe
    dma    = 3 + 16 + 16 + AW + R * AW + 32*3 + 32*3  # state, indices, latched fields, counters
    csr    = 3 + AW + 16 + 32 + 2                 # ctrl/base/count/scratch/sticky
    flops  = skew + part + vpipe + wpipe + dma + csr

    # ---- combinational (LUT-ish) ----
    pes    = R * P * (DW + 4)                     # R*P reduction PEs (add/mul/cmp select)
    addrs  = (R + 1) * AW                          # source + dest address adders
    mask   = P                                     # tail-mask comparators
    luts   = pes + addrs + mask

    print(f"# analytical area estimate (R={R}, P={P}, DW={DW}, AW={AW})")
    print(f"flops (approx)          : {flops}")
    print(f"  systolic skew regs    : {skew}")
    print(f"  stage partials        : {part}")
    print(f"  write-delay pipeline  : {wpipe}")
    print(f"  DMA fsm + counters    : {dma}")
    print(f"  CSR                   : {csr}")
    print(f"comb cells (approx LUTs): {luts}")
    print(f"  reduction PE array    : {pes}  ({R*P} PEs)")
    print(f"  address generators    : {addrs}")
    print("note: analytical estimate only; run `make synth` with Yosys for real numbers")

if __name__ == "__main__":
    main()
