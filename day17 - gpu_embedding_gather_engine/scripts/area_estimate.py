#!/usr/bin/env python3
"""Analytical resource estimate for emb_top.

Yosys is not installed on this machine, so `make synth` falls back to counting
the storage and arithmetic the RTL declares.  These are structural counts read
off the source, not synthesis results, and the README labels them as such.
"""
import argparse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dim", type=int, default=64)
    ap.add_argument("--lanes", type=int, default=4)
    ap.add_argument("--max-bag", type=int, default=64)
    a = ap.parse_args()

    dim, lanes, bag = a.dim, a.lanes, a.max_bag
    chunks = dim // lanes
    dw = lanes * 32

    stage = 2 * chunks * dw            # emb_stage_buf, two ping-pong buffers
    accum = chunks * dw                # emb_accum accumulator
    idxbuf = bag * 32                  # emb_core bag index buffer
    div = lanes * (34 * (32 + 32 + 33 + 32 + 8 + 2))   # pipelined divider stages
    csr = 19 * 32

    print("emb_top structural resource estimate")
    print(f"  geometry            EMB_DIM={dim} LANES={lanes} CHUNKS={chunks} "
          f"MAX_BAG={bag}")
    print(f"  memory data width   {dw} bits (AXI4 ARSIZE/AWSIZE = {dw//8} bytes)")
    print()
    print("  storage (flip-flops / distributed RAM bits)")
    print(f"    ping-pong staging buffers   {stage:6d}  (2 x {chunks} x {dw})")
    print(f"    pooling accumulator         {accum:6d}  ({chunks} x {dw})")
    print(f"    bag index buffer            {idxbuf:6d}  ({bag} x 32)")
    print(f"    MEAN divider pipelines      {div:6d}  ({lanes} x 34 stages)")
    print(f"    control / status registers  {csr:6d}")
    print(f"    total                       {stage+accum+idxbuf+div+csr:6d}")
    print()
    print("  arithmetic")
    print(f"    reduce lanes                {lanes:6d}  x (32-bit adder + "
          "signed compare-select)")
    print(f"    restoring dividers          {lanes:6d}  x 32-stage (1 subtract + "
          "1 compare per stage)")
    print("    row address                      1  x 32x32 multiply "
          "((index - shard_lo) * EMB_DIM)")
    print()
    print("  critical path: one reduce lane, i.e. a single 32-bit add or "
          "compare-select between the")
    print("  staging-buffer read and the accumulator write - the pooling fold "
          "is one adder deep by")
    print("  construction, which is why the fold keeps up with a full-rate "
          "memory burst.")


if __name__ == "__main__":
    main()
