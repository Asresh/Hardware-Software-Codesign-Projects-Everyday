# Author: Asresh
# Converts simulator key/value measurements into a committed Markdown table.
import re,sys
text=open(sys.argv[1],encoding="utf-8").read()
def get(k):
    m=re.search(r"^"+re.escape(k)+r"=([0-9.]+)$",text,re.M)
    if not m: raise SystemExit("missing "+k)
    return m.group(1)
print("<!-- Author: Asresh -->")
print("# Measured simulation results\n")
print("| Metric | Result |\n|---|---:|")
for key,label in [("VECTORS","Differential words"),("MISMATCHES","Mismatches"),("CYCLES","DMA scrub cycles"),("LATENCY_CYCLES","Descriptor latency (cycles)"),("THROUGHPUT_WORDS_PER_CYCLE","Throughput (words/cycle)"),("BASELINE_CYCLES","Scalar baseline cycles"),("SPEEDUP","Speedup")]:
    suffix="×" if key=="SPEEDUP" else ""
    print(f"| {label} | {get(key)}{suffix} |")
