# Author: Asresh
"""Extract only simulator-measured values into a committed Markdown table."""
from pathlib import Path
import re

text = Path("results/sim.log").read_text(encoding="utf-8")
keys = ["VECTORS", "CORE_CYCLES", "MEAN_LATENCY", "MAX_LATENCY", "THROUGHPUT",
        "BASELINE_CYCLES", "SPEEDUP", "MISMATCHES"]
labels = {
    "VECTORS": "Differential vectors", "CORE_CYCLES": "Aggregate launch-to-IRQ cycles",
    "MEAN_LATENCY": "Mean launch-to-IRQ latency (cycles)", "MAX_LATENCY": "Maximum latency (cycles)",
    "THROUGHPUT": "Non-overlapped commands/cycle", "BASELINE_CYCLES": "Scalar baseline cycles",
    "SPEEDUP": "Speedup", "MISMATCHES": "Mismatches",
}
print("<!-- Author: Asresh -->")
print("# Measured simulation results\n")
print("| Metric | Measured value |\n|---|---:|")
for key in keys:
    match = re.search(rf"^{key}=([^\n]+)$", text, re.MULTILINE)
    if not match:
        raise SystemExit(f"missing simulator metric {key}")
    value = match.group(1)
    if key == "SPEEDUP": value += "x"
    print(f"| {labels[key]} | {value} |")
