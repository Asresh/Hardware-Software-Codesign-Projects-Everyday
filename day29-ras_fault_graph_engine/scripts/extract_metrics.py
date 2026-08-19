# Author: Asresh
import re
from pathlib import Path
text=Path("results/sim.log").read_text(encoding="utf-8")
def value(name): return re.search(rf"^{name}=([^\n]+)",text,re.M).group(1)
print("<!-- Author: Asresh -->")
print("# Measured simulation results\n")
print("| Metric | Measured value |\n|---|---:|")
for key,label in [("GRAPHS","Graphs"),("CYCLES","End-to-end cycles"),("AVG_LATENCY","Average doorbell-to-interrupt latency (cycles)"),("THROUGHPUT","Throughput (graphs/clock)"),("BASELINE_CYCLES","Scalar baseline cycles"),("SPEEDUP","Speedup")]: print(f"| {label} | {value(key)} |")
print(f"| Mismatches | {value('MISMATCHES')} |")
