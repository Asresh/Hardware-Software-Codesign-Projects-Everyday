# Author: Asresh
# Diagram: simulation log -> METRIC parser -> Markdown results table
import re,sys
text=open(sys.argv[1],encoding="utf-8").read() if len(sys.argv)>1 else ""
vals=dict(re.findall(r"^METRIC\s+(\w+)\s+(\S+)",text,re.M))
print("<!-- Author: Asresh -->")
print("# Measured simulation results\n")
print("| Metric | Result |\n|---|---:|")
for key,label in [("vectors","Checked vectors"),("cycles","End-to-end cycles"),("latency","Pipeline latency (cycles)"),("throughput","Sustained samples/cycle"),("baseline_cycles","Software baseline cycles"),("speedup","Speedup"),("mismatches","Mismatches")]:
    value=vals.get(key,"missing")+("x" if key=="speedup" and key in vals else "")
    print(f"| {label} | {value} |")
