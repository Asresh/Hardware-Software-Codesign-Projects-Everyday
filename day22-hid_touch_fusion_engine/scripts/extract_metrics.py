#!/usr/bin/env python3
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"FRAMES=(\d+) MISMATCHES=(\d+) CORE_CYCLES=(\d+) AVG_LATENCY_X100=(\d+) BASELINE_CYCLES=(\d+)", text)
if not m:
    raise SystemExit("metrics marker missing")
frames, mismatches, cycles, lat100, baseline = map(int, m.groups())
latency = lat100 / 100.0
throughput = frames / cycles
speedup = baseline / cycles
print("# Measured simulation results\n")
print("| Metric | Result |\n|---|---:|")
print(f"| Differential frames | {frames} |")
print(f"| Mismatches | {mismatches} |")
print(f"| Core cycles | {cycles} |")
print(f"| Mean launch-to-IRQ latency | {latency:.2f} cycles |")
print(f"| Sustained non-overlapped throughput | {throughput:.5f} frames/cycle |")
print(f"| Scalar baseline | {baseline} cycles ({baseline/frames:.0f}/frame) |")
print(f"| Speedup over scalar baseline | {speedup:.2f}x |")
