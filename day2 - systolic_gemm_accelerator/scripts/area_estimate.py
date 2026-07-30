#!/usr/bin/env python3
"""Analytical area estimate for the systolic GEMM accelerator.

Yosys is not installed in this environment, so instead of a synthesized cell
report this prints a first-order resource estimate derived from the RTL
structure and the elaboration parameters. When Yosys/vendor tools are available
the `make synth` target runs them and this estimate is superseded.

usage: area_estimate.py --n N --data-width D --acc-width A --kmax K
"""
import argparse
import math


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--data-width", type=int, default=8)
    ap.add_argument("--acc-width", type=int, default=32)
    ap.add_argument("--kmax", type=int, default=64)
    a = ap.parse_args()

    N, D, ACC, K = a.n, a.data_width, a.acc_width, a.kmax
    pes = N * N

    # ---- sequential elements (flip-flops) ----
    ff_acc   = pes * ACC                 # one accumulator per PE
    ff_pass  = pes * 2 * D               # a_out + b_out pipeline regs per PE
    ff_skew  = 2 * (N * (N - 1) // 2) * D  # triangular A + B skew registers
    ff_buf   = 2 * N * K * D             # A^T and B operand SRAMs (if in FF)
    ff_ctrl  = 32 + 32 + 16 + 8          # cycle counter + cycles reg + t + flags
    ff_total = ff_acc + ff_pass + ff_skew + ff_ctrl   # buffers usually go to RAM

    # ---- arithmetic ----
    mult = pes                           # DxD signed multipliers -> DSP blocks
    add  = pes                           # ACC-width accumulate adders

    # ---- rough LUT estimate (generic 6-LUT fabric, no DSP hardening) ----
    lut_mult = mult * (D * D) // 2
    lut_add  = add * ACC
    lut_glue = ff_total // 4 + 300
    lut_total = lut_mult + lut_add + lut_glue

    print("Analytical area estimate (Yosys not present -- superseded by "
          "`make synth` where tools exist)\n")
    print(f"  Parameters : N={N}x{N} DATA={D} ACC={ACC} KMAX={K}  ({pes} PEs)\n")
    print("  Sequential (flip-flops)")
    print(f"    PE accumulators        {ff_acc:6d}   ({pes} x {ACC}b)")
    print(f"    PE pass-through regs    {ff_pass:6d}   ({pes} x 2 x {D}b)")
    print(f"    input skew registers    {ff_skew:6d}")
    print(f"    control / counters      {ff_ctrl:6d}")
    print(f"    ---- FF total           {ff_total:6d}\n")
    print("  Memory (LUTRAM/BRAM, not FF)")
    print(f"    A^T + B operand buffers {ff_buf:6d} bits ({2*N*K} bytes)\n")
    print("  Arithmetic")
    print(f"    signed multipliers     {mult:6d}   ({D}x{D}  -> ~{mult} DSP slices)")
    print(f"    accumulate adders      {add:6d}   ({ACC}b each)\n")
    print("  Combinational (generic 6-LUT fabric, no DSP hardening)")
    print(f"    ~ multipliers          {lut_mult:6d} LUT")
    print(f"    ~ adders               {lut_add:6d} LUT")
    print(f"    ~ glue/control         {lut_glue:6d} LUT")
    print(f"    ---- LUT total (approx){lut_total:6d} LUT")
    print("\n  Note: on a DSP-bearing FPGA the multipliers map to hard DSP "
          f"blocks ({mult} of them), and the operand buffers map to block RAM, "
          "cutting the LUT total to roughly the adder + glue terms "
          f"(~{lut_add + lut_glue} LUT).")


if __name__ == "__main__":
    main()
