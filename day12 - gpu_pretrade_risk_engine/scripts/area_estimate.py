#!/usr/bin/env python3
"""Analytical flop/LUT area estimate for the pre-trade risk engine.
Used when Yosys is unavailable. Rough, transparent, and clearly labelled as
an estimate - not a substitute for a real synthesis run."""
import argparse

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sym_n",  type=int, default=32)
    ap.add_argument("--acct_n", type=int, default=8)
    args = ap.parse_args()
    S, A = args.sym_n, args.acct_n
    POS = S * A

    # ---- flops ----
    sym_bits  = S * (32 + 32 + 32 + 64 + 1)      # lo,hi,maxqty,maxnot,en
    acct_bits = A * (32 + 32 + 1)                # poslimit,maxmsgs,en
    pos_bits  = POS * 32
    cnt_bits  = A * 32
    pipe_bits = (1 + 16 + 16 + 32 + 32 + 24 + 1) # stage E order regs
    dec_bits  = (1 + 24 + 1 + 4 + 16 + 16 + 32)  # stage D decision regs
    csr_bits  = 32 * 12 + 8                       # stats + control
    flops = sym_bits + acct_bits + pos_bits + cnt_bits + pipe_bits + dec_bits + csr_bits

    # ---- combinational (LUT-ish) ----
    mult   = 32 * 32              # notional 32x32 multiply
    cmps   = 6 * 40              # six gate comparators (wide)
    prio   = 40                  # priority encoder
    addr   = 200                 # index/key arithmetic + read muxes
    luts   = mult + cmps + prio + addr

    print(f"# analytical area estimate (SYM_N={S}, ACCT_N={A}, POS={POS})")
    print(f"flops (approx)          : {flops}")
    print(f"  symbol config table   : {sym_bits}")
    print(f"  account config table  : {acct_bits}")
    print(f"  position RAM          : {pos_bits}")
    print(f"  count RAM             : {cnt_bits}")
    print(f"  pipeline + decision   : {pipe_bits + dec_bits}")
    print(f"  CSR / stats           : {csr_bits}")
    print(f"comb cells (approx LUTs): {luts}")
    print(f"  32x32 notional mult   : {mult}")
    print(f"  6 gate comparators    : {cmps}")
    print(f"  priority encoder      : {prio}")
    print(f"  index/read muxes      : {addr}")
    print("note: analytical estimate only; run `make synth` with Yosys for real numbers")

if __name__ == "__main__":
    main()
