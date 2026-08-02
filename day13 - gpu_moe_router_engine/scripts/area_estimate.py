#!/usr/bin/env python3
"""Analytical flop/LUT area estimate for the MoE router engine.
Used when Yosys is unavailable. Rough, transparent, clearly an estimate."""
import argparse

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--e", type=int, default=8)
    ap.add_argument("--k", type=int, default=2)
    args = ap.parse_args()
    E, K = args.e, args.k
    NUMW, DIVW = 34, 18

    # ---- flops ----
    ingest = E * 16 + 16 + 16 + 1          # logits + tid + counter + valid
    sel    = 16 + 8 + 16 + 8 + 16 + 1      # max,e0,t1,e1,tid,valid
    smx    = 2 * NUMW + DIVW + 8 + 8 + 16 + 1  # num0,num1,den,e0,e1,tid,valid
    div    = 2 * (NUMW * (NUMW + (DIVW + 1) + NUMW + DIVW + 1))  # two pipelines
    sbline = (NUMW + 1) * (1 + 16 + 8 + 8) # sideband delay
    caps   = E * 32 + 3 * 32               # load counters + 3 stats
    csr    = 3 + 32 + 32 + 1               # ctrl + cap + scratch + irq
    flops  = ingest + sel + smx + div + sbline + caps + csr

    # ---- combinational (LUT-ish) ----
    topk   = 2 * E * 20                    # two argmax reductions over E
    explut = 257 * DIVW                    # exp LUT ROM (block ROM in practice)
    interp = DIVW * 6                      # exp interpolation mult/sub
    divcmp = 2 * NUMW * (DIVW + 4)         # per-stage compare/subtract
    pack   = 128
    luts   = topk + interp + divcmp + pack

    print(f"# analytical area estimate (E={E}, K={K}, NUMW={NUMW}, DIVW={DIVW})")
    print(f"flops (approx)          : {flops}")
    print(f"  ingest / select / smx : {ingest + sel + smx}")
    print(f"  two divider pipelines : {div}")
    print(f"  sideband delay line   : {sbline}")
    print(f"  capacity + stats      : {caps}")
    print(f"  CSR                   : {csr}")
    print(f"comb cells (approx LUTs): {luts}")
    print(f"  top-k argmax trees    : {topk}")
    print(f"  exp interpolation     : {interp}")
    print(f"  divider stage logic   : {divcmp}")
    print(f"exp LUT ROM bits        : {explut}  (257 x {DIVW}b, maps to block ROM)")
    print("note: analytical estimate only; run `make synth` with Yosys for real numbers")

if __name__ == "__main__":
    main()
