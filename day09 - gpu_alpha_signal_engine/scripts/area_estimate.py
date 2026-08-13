#!/usr/bin/env python3
"""Analytical flop/gate estimate for the alpha-signal engine.

Yosys is not installed in this environment, so instead of a synthesized cell
report we give a transparent register/adder count derived from the parameters.
Numbers are register-bit and adder-cell counts, not a placed-and-routed area.
"""
import argparse

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--nsym',  type=int, default=64)
    ap.add_argument('--frac',  type=int, default=16)
    ap.add_argument('--eww',   type=int, default=32)
    ap.add_argument('--varw',  type=int, default=48)
    ap.add_argument('--isqrt', type=int, default=32)
    ap.add_argument('--div',   type=int, default=48)
    a = ap.parse_args()

    stw   = 2*a.eww + a.varw + 32                  # symbol-state word
    meta  = 257 + (a.nsym - 1).bit_length()        # pipeline payload width
    pay2  = meta + 32

    sym_ram   = a.nsym * stw
    isqrt_ff  = (a.isqrt + 1) * (64 + 64 + meta + 1)
    div_ff    = (a.div + 1) * (a.div + 32 + a.div + (32+2) + pay2 + 1)
    egress_ff = 256 + 32*4 + 3
    ctrl_ff   = 32*7 + 8

    total_ff = sym_ram + isqrt_ff + div_ff + egress_ff + ctrl_ff

    # comparator/adder cells: one per pipeline stage plus the RMW multipliers
    isqrt_add = a.isqrt * 2
    div_add   = a.div  * 2
    rmw_mul   = 4                                  # 64-bit signed multiplies
    rmw_add   = 8

    print("Alpha-signal engine - analytical area estimate")
    print(f"  parameters: N_SYM={a.nsym} FRAC={a.frac} EWW={a.eww} VARW={a.varw} "
          f"ISQRT={a.isqrt} DIV={a.div}")
    print(f"  symbol-state word            : {stw} bits x {a.nsym} = {sym_ram} FF")
    print(f"  isqrt pipeline               : {isqrt_ff} FF")
    print(f"  divider pipeline             : {div_ff} FF")
    print(f"  egress register + control    : {egress_ff + ctrl_ff} FF")
    print(f"  -------------------------------------------")
    print(f"  total sequential (flops)     : ~{total_ff} FF")
    print(f"  sqrt/divide comparator-adders: ~{isqrt_add + div_add}")
    print(f"  RMW datapath multipliers     : {rmw_mul} x 64-bit, {rmw_add} adders")
    print(f"  pipeline latency             : ~{a.isqrt + a.div + 4} cycles")
    print(f"  sustained throughput         : 1 tick / clock")

if __name__ == '__main__':
    main()
