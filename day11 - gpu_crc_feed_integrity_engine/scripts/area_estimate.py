#!/usr/bin/env python3
# Analytical flop/LUT estimate (Yosys is not installed in this environment).
# Counts the dominant registers and combinational operators from the RTL
# structure so the README can quote an order-of-magnitude area without synth.
import argparse

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--chw', type=int, default=8)
    a = ap.parse_args()
    CHW = a.chw
    NCH = 1 << CHW

    ff = {
        'parser CRC state + framing regs': 32 + 16*3 + 3,     # crc,channel,plen,rem,state
        'parser result registers': 16 + 32*3 + 16 + 4,        # channel,seq,crc,exp,plen,flags
        'seq_tracker RAM (last_seq)': NCH * 32,
        'seq_tracker valid bits': NCH,
        'regfile counters (6 x 32b)': 6 * 32,
        'regfile snapshot regs': 16 + 32*4 + 4,
        'regfile ctrl/scratch/irq + AXI handshake': 3 + 32 + 1 + 6,
    }
    lut = {
        'crc32_unit x2 (4-byte GF(2) fold, ~8 xor/byte)': 2 * 4 * 8 * 32,
        'nbytes select + finalise mux': 32 * 3,
        'seq compare / gap detect': 32 * 2,
        'AXI4-Lite addr decode + read mux': 16 * 32,
    }
    tot_ff = sum(ff.values())
    tot_lut = sum(lut.values())
    print(f"Analytical area estimate (CHW={CHW}, NCH={NCH})")
    print("-" * 56)
    print("Flip-flops:")
    for k, v in ff.items():
        print(f"  {k:<48} {v:>6}")
    print(f"  {'TOTAL FF':<48} {tot_ff:>6}")
    print("Combinational (approx 6-LUT equivalents):")
    for k, v in lut.items():
        print(f"  {k:<48} {v:>6}")
    print(f"  {'TOTAL LUT':<48} {tot_lut:>6}")
    print("-" * 56)
    print("Note: the per-channel sequence RAM dominates FF count and would map")
    print("to block/distributed RAM on an FPGA rather than fabric flops.")

if __name__ == '__main__':
    main()
