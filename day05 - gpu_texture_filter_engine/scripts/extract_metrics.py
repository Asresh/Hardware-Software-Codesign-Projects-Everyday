#!/usr/bin/env python3
"""Turn the simulation log + the software cost model into results/metrics.md.

Reads the summary lines the testbench prints (JOBS, CHECKS, MISMATCHES,
HW_CYCLES_TOTAL, PIXELS_TOTAL, PEAK_PIXELS, PEAK_CYCLES) and the baseline cost
model written by tex_host (cpp, total_output_pixels, total_baseline_cycles).
Emits a Markdown table of measured numbers only."""
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
    pixels = sim.get("PIXELS_TOTAL", 0)
    peak_pix = sim.get("PEAK_PIXELS", 0)
    peak_cyc = sim.get("PEAK_CYCLES", 0)

    cpp = sw.get("cpp", 0)
    base_cyc = sw.get("total_baseline_cycles", 0)

    # effective baseline ops/pixel (includes per-row overhead)
    cpp_eff = (base_cyc / pixels) if pixels else 0.0
    sustained = (pixels / hw_cyc) if hw_cyc else 0.0          # pixels / cycle
    peak_tp = (peak_pix / peak_cyc) if peak_cyc else 0.0      # pixels / cycle
    agg_speedup = (base_cyc / hw_cyc) if hw_cyc else 0.0
    peak_base = cpp_eff * peak_pix
    peak_speedup = (peak_base / peak_cyc) if peak_cyc else 0.0

    print("# Measured results\n")
    print("Extracted from `results/sim.log` (Icarus Verilog) and the scalar "
          "baseline cost model. Hardware cycles are measured from RTL "
          "simulation; the software baseline is a dynamic instruction count "
          "over the real pixel workload at one op per cycle.\n")
    print("| Metric | Value |")
    print("|---|---|")
    print(f"| Jobs run | {jobs} |")
    print(f"| Output words checked | {checks} |")
    print(f"| Mismatches vs golden | {mism} |")
    print(f"| Output pixels filtered | {pixels} |")
    print(f"| Total hardware cycles | {hw_cyc} |")
    print(f"| Sustained throughput | {sustained:.2f} pixels/cycle |")
    print(f"| Peak job pixels | {peak_pix} |")
    print(f"| Peak job cycles | {peak_cyc} |")
    print(f"| Peak throughput | {peak_tp:.2f} pixels/cycle |")
    print(f"| Scalar baseline (model) | {cpp} ops/pixel core, "
          f"{cpp_eff:.1f} effective |")
    print(f"| Aggregate baseline cycles | {base_cyc} |")
    print(f"| Aggregate speedup | {agg_speedup:.2f}x |")
    print(f"| Peak speedup | {peak_speedup:.2f}x |")
    print()
    print("Ideal steady-state throughput is 1.0 pixel/cycle (the blend datapath "
          f"retires one filtered pixel per clock); the peak measured "
          f"{peak_tp:.2f} pixels/cycle is that bound minus line-buffer load and "
          "the fixed per-row/per-job setup.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
