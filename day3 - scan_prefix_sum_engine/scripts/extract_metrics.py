#!/usr/bin/env python3
"""Turn the simulation log + the software cost model into results/metrics.md.

Reads the summary lines the testbench prints (JOBS, CHECKS, MISMATCHES,
HW_CYCLES_TOTAL, ELEMS_TOTAL, PEAK_LEN, PEAK_CYCLES, LANES) and the baseline
cycle model written by scan_host (cpe, total_baseline_cycles). Emits a Markdown
table of measured numbers only."""
import sys


def parse_kv(path, sep=None):
    d = {}
    with open(path) as f:
        for line in f:
            parts = line.split(sep)
            if len(parts) >= 2:
                key = parts[0].strip()
                val = parts[1].strip()
                try:
                    d[key] = int(val)
                except ValueError:
                    pass
    return d


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: extract_metrics.py sim.log sw_metrics.txt\n")
        return 1
    sim = parse_kv(sys.argv[1])
    sw = parse_kv(sys.argv[2])

    jobs = sim.get("JOBS", 0)
    checks = sim.get("CHECKS", 0)
    mism = sim.get("MISMATCHES", -1)
    hw_cyc = sim.get("HW_CYCLES_TOTAL", 0)
    elems = sim.get("ELEMS_TOTAL", 0)
    peak_len = sim.get("PEAK_LEN", 0)
    peak_cyc = sim.get("PEAK_CYCLES", 0)
    lanes = sim.get("LANES", 0)

    cpe = sw.get("cpe", 3)
    base_cyc = sw.get("total_baseline_cycles", 0)

    sustained = (elems / hw_cyc) if hw_cyc else 0.0      # words / cycle
    peak_tp = (peak_len / peak_cyc) if peak_cyc else 0.0  # words / cycle
    agg_speedup = (base_cyc / hw_cyc) if hw_cyc else 0.0
    peak_base = cpe * peak_len
    peak_speedup = (peak_base / peak_cyc) if peak_cyc else 0.0

    print("# Measured results\n")
    print("Extracted from `results/sim.log` (Icarus Verilog) and the scalar "
          "baseline cost model. Numbers are measured, not asserted.\n")
    print("| Metric | Value |")
    print("|---|---|")
    print(f"| Jobs run | {jobs} |")
    print(f"| Output words checked | {checks} |")
    print(f"| Mismatches vs golden | {mism} |")
    print(f"| Lanes (words/beat) | {lanes} |")
    print(f"| Total hardware cycles | {hw_cyc} |")
    print(f"| Total elements scanned | {elems} |")
    print(f"| Sustained throughput | {sustained:.2f} words/cycle |")
    print(f"| Peak job length | {peak_len} elements |")
    print(f"| Peak job cycles | {peak_cyc} |")
    print(f"| Peak throughput | {peak_tp:.2f} words/cycle |")
    print(f"| Scalar baseline (model) | {cpe} cycles/element |")
    print(f"| Aggregate baseline cycles | {base_cyc} |")
    print(f"| Aggregate speedup | {agg_speedup:.2f}x |")
    print(f"| Peak speedup | {peak_speedup:.2f}x |")
    print()
    print(f"Ideal steady-state throughput is {lanes} words/cycle (one coalesced "
          f"{lanes}-word beat per clock); the peak measured {peak_tp:.2f} "
          "words/cycle is that bound minus the fixed pipeline fill/drain.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
