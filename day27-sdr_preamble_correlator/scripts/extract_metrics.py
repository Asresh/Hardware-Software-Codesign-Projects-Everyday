# Author: Asresh
"""Convert the simulator's measured counters into a committed Markdown table."""
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"METRICS vectors=(\d+) cycles=(\d+) latency=(\d+) baseline=(\d+) checks=(\d+) mismatches=(\d+)", text)
if not match:
    raise SystemExit("METRICS line missing")
vectors, cycles, latency, baseline, checks, mismatches = map(int, match.groups())
throughput = vectors / cycles
speedup = baseline / cycles
print("<!-- Author: Asresh -->")
print("| Metric | Measured value |")
print("|---|---:|")
print(f"| Full-rate vectors | {vectors} |")
print(f"| Full-rate cycles | {cycles} |")
print(f"| First-result latency | {latency} cycles |")
print(f"| Sustained throughput | {throughput:.3f} vectors/clock |")
print(f"| Scalar baseline | {baseline} modeled cycles |")
print(f"| Speedup over scalar | {speedup:.2f}x |")
print(f"| Differential checks | {checks} |")
print(f"| Mismatches | {mismatches} |")
