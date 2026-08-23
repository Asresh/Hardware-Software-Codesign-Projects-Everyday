# Author: Asresh
import pathlib
import re
import sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"METRIC jobs=(\d+) joints=(\d+) cycles=(\d+) throughput=([0-9.]+) latency=([0-9.]+) baseline_cycles=(\d+) speedup=([0-9.]+) mismatches=(\d+)", text)
if not match:
    raise SystemExit("metrics line missing")
jobs,joints,cycles,throughput,latency,baseline,speedup,mismatches=match.groups()
print("<!-- Author: Asresh -->")
print("| Metric | Measured value |")
print("|---|---:|")
print(f"| Kinematic chains | {jobs} |")
print(f"| Joint vectors | {joints} |")
print(f"| SPI end-to-end cycles | {cycles} |")
print(f"| CORDIC datapath throughput | {float(throughput):.6f} joints/clock |")
print(f"| Mean START-to-interrupt latency | {float(latency):.3f} cycles |")
print(f"| Scalar software baseline | {baseline} cycles |")
print(f"| End-to-end speedup | {float(speedup):.3f}x |")
print(f"| Mismatches | {mismatches} |")
