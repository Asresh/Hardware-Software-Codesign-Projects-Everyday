# Author: Asresh
import re,sys
text=open(sys.argv[1] if len(sys.argv)>1 else "results/sim.log",encoding="utf-8").read()
keys=["REQUESTS","CYCLES","AVG_LATENCY","THROUGHPUT","BASELINE_CYCLES","SPEEDUP","MISMATCHES"]
vals={k:re.search(rf"^{k}=([^\n]+)",text,re.M).group(1) for k in keys}
print("<!-- Author: Asresh -->")
print("# Measured simulation results\n")
print("| Metric | Measured value |\n|---|---:|")
for k in keys: print(f"| {k.lower().replace('_',' ')} | {vals[k]} |")
