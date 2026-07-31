#!/usr/bin/env python3
"""Turn the simulation log + the software cost model into results/metrics.md.

Reads the summary lines the testbench prints (JOBS, CHECKS, MISMATCHES,
HW_CYCLES_TOTAL, DRAWS_TOTAL, WORDS_TOTAL, PEAK_DRAWS, PEAK_CYCLES) and the
baseline cost model written by philox_host (lanes, opd, total_draws,
total_words, total_baseline_cycles). Emits a Markdown table of measured numbers
only."""
import sys


def parse_kv(path, sep=None):
    d = {}
    with open(path) as f:
        for line in f:
            parts = line.split(sep)
            if len(parts) >= 2:
                key = parts[0].strip()
                try:
                    d[key] = int(parts[1].strip())
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
    draws = sim.get("DRAWS_TOTAL", 0)
    words = sim.get("WORDS_TOTAL", 0)
    peak_draws = sim.get("PEAK_DRAWS", 0)
    peak_cyc = sim.get("PEAK_CYCLES", 0)

    lanes = sw.get("lanes", 0)
    opd = sw.get("opd", 0)
    base_cyc = sw.get("total_baseline_cycles", 0)

    ideal_draws = lanes                      # draws / cycle
    ideal_words = lanes * 4                  # 32-bit random words / cycle
    sust_draws = (draws / hw_cyc) if hw_cyc else 0.0
    sust_words = (words / hw_cyc) if hw_cyc else 0.0
    peak_dpc = (peak_draws / peak_cyc) if peak_cyc else 0.0
    peak_wpc = (peak_draws * 4 / peak_cyc) if peak_cyc else 0.0
    agg_speedup = (base_cyc / hw_cyc) if hw_cyc else 0.0
    peak_base = opd * peak_draws
    peak_speedup = (peak_base / peak_cyc) if peak_cyc else 0.0

    print("# Measured results\n")
    print("Extracted from `results/sim.log` (Icarus Verilog) and the scalar "
          "baseline cost model. Hardware cycles are measured from RTL "
          "simulation; the software baseline is a dynamic instruction count "
          "over the real draw workload at one op per cycle.\n")
    print("| Metric | Value |")
    print("|---|---|")
    print(f"| Jobs run | {jobs} |")
    print(f"| Random words checked | {checks} |")
    print(f"| Mismatches vs golden | {mism} |")
    print(f"| Philox draws generated | {draws} |")
    print(f"| Random 32-bit words generated | {words} |")
    print(f"| Total hardware cycles | {hw_cyc} |")
    print(f"| Sustained throughput | {sust_draws:.2f} draws/cycle "
          f"({sust_words:.2f} words/cycle) |")
    print(f"| Peak job draws | {peak_draws} |")
    print(f"| Peak job cycles | {peak_cyc} |")
    print(f"| Peak throughput | {peak_dpc:.2f} draws/cycle "
          f"({peak_wpc:.2f} words/cycle) |")
    print(f"| Ideal throughput | {ideal_draws}.0 draws/cycle "
          f"({ideal_words}.0 words/cycle) |")
    print(f"| Scalar baseline (model) | {opd} ops/draw |")
    print(f"| Aggregate baseline cycles | {base_cyc} |")
    print(f"| Aggregate speedup | {agg_speedup:.2f}x |")
    print(f"| Peak speedup | {peak_speedup:.2f}x |")
    print()
    print(f"Ideal steady-state throughput is {ideal_draws}.0 draws/cycle "
          f"({ideal_words}.0 random words/cycle): the {lanes}-lane SIMD array "
          f"retires one Philox-4x32-10 block per lane per clock. The peak "
          f"measured {peak_dpc:.2f} draws/cycle is that bound minus the fixed "
          "pipeline fill/drain (the lanes are ROUNDS stages deep) and per-job "
          "setup; the gap shrinks with longer jobs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
