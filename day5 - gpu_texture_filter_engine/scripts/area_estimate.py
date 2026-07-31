#!/usr/bin/env python3
"""Analytical area/flop estimate for the bilinear texture-filter engine.

Yosys is not installed in this environment, so instead of a synthesized cell
report this prints a first-order structural estimate derived from the
parameters: the two-row line buffer, the bilinear blend multipliers, the two
coordinate resolvers, and the sequencer / mailbox state. It is an estimate,
labelled as such; it is not a synthesis result."""
import argparse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wmax", type=int, default=64)
    ap.add_argument("--addr-width", type=int, default=20)
    a = ap.parse_args()

    WMAX, AW = a.wmax, a.addr_width
    PIX = 8

    # --- line buffer: two rows of WMAX bytes (registers / distributed RAM) ---
    lb_bits = 2 * WMAX * PIX
    lb_ff = lb_bits

    # --- blend datapath: 3 lerps -> ~6 (8x9) multiplies + adds/shift ---
    mult_gates = 6 * (PIX * 9) * 6          # ~6 gates / bit-product cell
    add_gates = 3 * 18 * 5                  # three ~18-bit adders

    # --- coordinate resolvers: 2x (compare + increment + mux), 32-bit acc ---
    coord_gates = 2 * (32 * 3 + 16 * 4)

    # --- sequencer + mailbox: ~12 CSR words + FSM + accumulators/counters ---
    csr_ff = 12 * 32
    seq_ff = 2 * 32 + 6 * 16 + 3 * AW + 32   # ux,uy + counters + bases + cyc
    seq_gates = 900

    total_ff = lb_ff + csr_ff + seq_ff
    total_gates = (mult_gates + add_gates + coord_gates + seq_gates +
                   lb_bits * 2)             # + line-buffer write/read muxing

    print("Analytical area estimate (NOT a synthesis result; Yosys absent)")
    print("-------------------------------------------------------------")
    print(f"  parameters      : WMAX={WMAX}  ADDR_WIDTH={AW}  PIX_W={PIX}")
    print(f"  line buffer FF  : {lb_ff:6d}  (2 rows x {WMAX} x {PIX}b)")
    print(f"  CSR / mailbox FF: {csr_ff:6d}")
    print(f"  sequencer FF    : {seq_ff:6d}")
    print(f"  flip-flops (est): {total_ff:6d}")
    print(f"  blend mult gates: {mult_gates:6d}")
    print(f"  logic gates (est): {total_gates:6d}")
    print("  critical path   : line-buffer read -> 3 lerp multiplies -> pack")
    print("                    (would be pipelined for fmax in silicon)")


if __name__ == "__main__":
    main()
