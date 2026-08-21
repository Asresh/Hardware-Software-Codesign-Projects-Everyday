# Author: Asresh
import pathlib
import re
import sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"METRIC vectors=(\d+) scans=(\d+) cycles=(\d+) throughput=([0-9.]+) latency=([0-9.]+) baseline_cycles=(\d+) speedup=([0-9.]+) mismatches=(\d+)", text)
if not match:
    raise SystemExit("metrics line missing")
vectors, scans, cycles, throughput, latency, baseline, speedup, mismatches = match.groups()
print("<!-- Author: Asresh -->")
print("| Metric | Measured value |")
print("|---|---:|")
print(f"| Differential vectors | {vectors} |")
print(f"| Scan jobs | {scans} |")
print(f"| End-to-end cycles | {cycles} |")
print(f"| Sustained throughput | {float(throughput):.6f} samples/clock |")
print(f"| Mean first-sample-to-interrupt latency | {float(latency):.3f} cycles |")
print(f"| Scalar baseline | {baseline} cycles |")
print(f"| Speedup | {float(speedup):.3f}x |")
print(f"| Mismatches | {mismatches} |")
