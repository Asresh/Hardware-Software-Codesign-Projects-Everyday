#!/usr/bin/env python3
"""Analytical area estimate for the FIR accelerator.

Yosys is not installed in this environment, so instead of a synthesized cell
report this prints a first-order resource estimate derived from the RTL
structure and the elaboration parameters. When Yosys/vendor tools are available
the `make synth` target runs them and this estimate is superseded.

usage: area_estimate.py --data-width D --coef-width C --taps T --fifo-depth F
"""
import argparse
import math


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-width", type=int, default=16)
    ap.add_argument("--coef-width", type=int, default=16)
    ap.add_argument("--taps", type=int, default=8)
    ap.add_argument("--fifo-depth", type=int, default=16)
    ap.add_argument("--len-width", type=int, default=16)
    a = ap.parse_args()

    D, C, T, F = a.data_width, a.coef_width, a.taps, a.fifo_depth
    lg_t = math.ceil(math.log2(T)) if T > 1 else 0
    acc = D + C + lg_t
    ptr = int(math.ceil(math.log2(F))) + 1

    # ---- sequential elements (flip-flops) ----
    ff_acc   = T * acc                 # transposed accumulator chain
    ff_coef  = T * C                   # coefficient shadow registers
    ff_fifos = ptr * 2 * 2             # 2 FIFOs, wr/rd pointer each
    ff_ctrl  = 32 + a.len_width + 8    # samples_out(32) + length + status/flags
    ff_total = ff_acc + ff_coef + ff_fifos + ff_ctrl

    # ---- memory bits (typically LUTRAM/BRAM, not FF) ----
    mem_bits = F * D + F * (acc + 1)   # input FIFO + output FIFO (+TLAST bit)

    # ---- arithmetic ----
    mult = T                           # DxC signed multipliers -> DSP blocks
    add  = T - 1                       # acc-width adders in the chain

    # ---- rough LUT estimate (generic 6-LUT fabric, no DSP hardening) ----
    # multiplier ~ D*C/2 LUTs (array multiplier), adder ~ acc LUTs, plus glue.
    lut_mult = mult * (D * C) // 2
    lut_add  = add * acc
    lut_glue = ff_total // 4 + 200
    lut_total = lut_mult + lut_add + lut_glue

    print("Analytical area estimate (Yosys not present) -- superseded by "
          "`make synth` where tools exist)\n")
    print(f"  Parameters : DATA={D} COEF={C} TAPS={T} ACC={acc} FIFO_DEPTH={F}\n")
    print("  Sequential (flip-flops)")
    print(f"    accumulator chain      {ff_acc:6d}   ({T} x {acc}b)")
    print(f"    coefficient registers  {ff_coef:6d}   ({T} x {C}b)")
    print(f"    FIFO pointers          {ff_fifos:6d}")
    print(f"    control / status       {ff_ctrl:6d}")
    print(f"    ---- FF total          {ff_total:6d}\n")
    print("  Memory (LUTRAM/BRAM, not FF)")
    print(f"    FIFO storage           {mem_bits:6d} bits\n")
    print("  Arithmetic")
    print(f"    signed multipliers     {mult:6d}   ({D}x{C}  -> ~{mult} DSP slices)")
    print(f"    accumulator adders     {add:6d}   ({acc}b each)\n")
    print("  Combinational (generic 6-LUT fabric, no DSP hardening)")
    print(f"    ~ multipliers          {lut_mult:6d} LUT")
    print(f"    ~ adders               {lut_add:6d} LUT")
    print(f"    ~ glue/control         {lut_glue:6d} LUT")
    print(f"    ---- LUT total (approx){lut_total:6d} LUT")
    print("\n  Note: on a DSP-bearing FPGA the multipliers map to hard DSP "
          "blocks, cutting the LUT total to roughly the adder + glue terms "
          f"(~{lut_add + lut_glue} LUT) plus {mult} DSPs.")


if __name__ == "__main__":
    main()
