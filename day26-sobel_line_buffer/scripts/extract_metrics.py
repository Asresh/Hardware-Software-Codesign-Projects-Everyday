# Author: Asresh
"""Convert simulator METRIC lines into the committed measurement report."""
import re,sys
text=open(sys.argv[1],encoding="utf-8").read();m={k:int(v) for k,v in re.findall(r"METRIC (\w+)=(\d+)",text)}
through=m["output_pixels"]/m["cycles"];speed=m["baseline_cycles"]/m["cycles"]
print("<!-- Author: Asresh -->")
print("# Measured simulation results\n")
print("| Metric | Result |\n|---|---:|")
for label,key in [("Input pixels","input_pixels"),("Seeded random pixels","random_pixels"),("Output pixels checked","output_pixels"),("Launch-to-interrupt cycles","cycles"),("Pipeline latency","latency_cycles"),("Scalar baseline cycles","baseline_cycles"),("Mismatches","mismatches")]:print(f"| {label} | {m[key]} |")
print(f"| Sustained output throughput | {through:.6f} pixels/cycle |")
print(f"| Speedup over scalar baseline | {speed:.6f}x |")
