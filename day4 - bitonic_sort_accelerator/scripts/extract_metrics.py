#!/usr/bin/env python3
"""Turn the simulation log + the software cost model into results/metrics.md.

Reads the summary lines the testbench prints (JOBS, CHECKS, MISMATCHES,
HW_CYCLES_TOTAL, TILES_TOTAL, KEYS_TOTAL, PEAK_KEYS, PEAK_CYCLES, N) and the
baseline cycle model written by sort_host (cpt, total_baseline_cycles). Emits a
Markdown table of measured numbers only."""
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
    tiles = sim.get("TILES_TOTAL", 0)
    keys = sim.get("KEYS_TOTAL", 0)
    peak_keys = sim.get("PEAK_KEYS", 0)
    peak_cyc = sim.get("PEAK_CYCLES", 0)
    n = sim.get("N", 0)

    cpt = sw.get("cpt", 0)
    base_cyc = sw.get("total_baseline_cycles", 0)

    sustained = (keys / hw_cyc) if hw_cyc else 0.0        # keys / cycle
    peak_tp = (peak_keys / peak_cyc) if peak_cyc else 0.0  # keys / cycle
    agg_speedup = (base_cyc / hw_cyc) if hw_cyc else 0.0
    peak_tiles = (peak_keys // n) if n else 0
    peak_base = cpt * peak_tiles
    peak_speedup = (peak_base / peak_cyc) if peak_cyc else 0.0

    print("# Measured results\n")
    print("Extracted from `results/sim.log` (Icarus Verilog) and the scalar "
          "baseline cost model. Numbers are measured, not asserted.\n")
    print("| Metric | Value |")
    print("|---|---|")
    print(f"| Jobs run | {jobs} |")
    print(f"| Output keys checked | {checks} |")
    print(f"| Mismatches vs golden | {mism} |")
    print(f"| Keys per tile (N) | {n} |")
    print(f"| Tiles sorted | {tiles} |")
    print(f"| Total hardware cycles | {hw_cyc} |")
    print(f"| Total keys sorted | {keys} |")
    print(f"| Sustained throughput | {sustained:.2f} keys/cycle |")
    print(f"| Peak job keys | {peak_keys} |")
    print(f"| Peak job cycles | {peak_cyc} |")
    print(f"| Peak throughput | {peak_tp:.2f} keys/cycle |")
    print(f"| Scalar baseline (model) | {cpt} cycles/tile |")
    print(f"| Aggregate baseline cycles | {base_cyc} |")
    print(f"| Aggregate speedup | {agg_speedup:.2f}x |")
    print(f"| Peak speedup | {peak_speedup:.2f}x |")
    print()
    print(f"Ideal steady-state throughput is {n} keys/cycle (one coalesced "
          f"{n}-key tile sorted per clock); the peak measured {peak_tp:.2f} "
          "keys/cycle is that bound minus the fixed pipeline fill/drain.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
