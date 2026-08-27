# Author: Asresh
import re
from pathlib import Path

text = Path("results/sim.log").read_text(encoding="utf-8")
match = re.search(
    r"TEST PASSED records=(\d+) packets=(\d+) mismatches=(\d+) total_cycles=(\d+) "
    r"engine_cycles=(\d+) latency=(\d+) throughput=([0-9.]+) "
    r"baseline_cycles=(\d+) speedup=([0-9.]+)", text)
if match is None:
    raise SystemExit("metrics line missing")
records, packets, mismatches, total, engine, latency, rate, baseline, speedup = match.groups()
print("<!-- Author: Asresh -->")
print("# Measured simulation results")
print()
print("| Metric | Value |")
print("|---|---:|")
print(f"| Input trace records | {records} |")
print(f"| Compressed packets | {packets} |")
print(f"| End-to-end START-to-IRQ cycles | {total} |")
print(f"| Accelerator busy cycles | {engine} |")
print(f"| Accelerator throughput | {rate} records/clock |")
print(f"| Scalar baseline | {baseline} cycles |")
print(f"| End-to-end speedup | {speedup}x |")
print(f"| Mismatches | {mismatches} |")
