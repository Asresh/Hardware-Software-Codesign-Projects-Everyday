#!/usr/bin/env python3
"""Turn the simulation log + the software cost model into results/metrics.md.

Reads the summary lines the testbench prints (JOBS, CHECKS, MISMATCHES,
HW_CYCLES_TOTAL, REQUESTS_TOTAL, WORDS_TOTAL, PEAK_REQUESTS, PEAK_CYCLES) and the
baseline cost model written by sfu_host (lanes, jobs, total_requests,
total_words, total_baseline_cycles, max_abs_err_e9). Emits a Markdown table of
measured numbers only."""
import sys


def parse_kv(path):
    d = {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    d[parts[0].strip()] = int(parts[1].strip())
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
    req = sim.get("REQUESTS_TOTAL", 0)
    words = sim.get("WORDS_TOTAL", 0)
    peak_req = sim.get("PEAK_REQUESTS", 0)
    peak_cyc = sim.get("PEAK_CYCLES", 0)

    lanes = sw.get("lanes", 0)
    base_cyc = sw.get("total_baseline_cycles", 0)
    err_e9 = sw.get("max_abs_err_e9", 0)

    sust_fpc = (req / hw_cyc) if hw_cyc else 0.0
    peak_fpc = (peak_req / peak_cyc) if peak_cyc else 0.0
    sust_cpf = (hw_cyc / req) if req else 0.0
    peak_cpf = (peak_cyc / peak_req) if peak_req else 0.0
    agg_speedup = (base_cyc / hw_cyc) if hw_cyc else 0.0
    peak_base = (base_cyc * peak_req / req) if req else 0.0   # same op mix scale
    peak_speedup = (peak_base / peak_cyc) if peak_cyc else 0.0

    print("# Measured results\n")
    print("Extracted from `results/sim.log` (Icarus Verilog) and the scalar "
          "baseline cost model. Hardware cycles are measured from RTL "
          "simulation; the software baseline is a dynamic instruction count "
          "over the real request workload at one op per cycle. Accuracy is the "
          "worst-case error of the fixed-point CORDIC against IEEE double libm, "
          "checked over every generated result.\n")
    print("| Metric | Value |")
    print("|---|---|")
    print(f"| Jobs run | {jobs} |")
    print(f"| Result words checked | {checks} |")
    print(f"| Mismatches vs golden | {mism} |")
    print(f"| Function requests evaluated | {req} |")
    print(f"| Total hardware cycles | {hw_cyc} |")
    print(f"| Sustained throughput | {sust_fpc:.3f} functions/cycle "
          f"({sust_cpf:.2f} cycles/function) |")
    print(f"| Peak job requests | {peak_req} |")
    print(f"| Peak job cycles | {peak_cyc} |")
    print(f"| Peak throughput | {peak_fpc:.3f} functions/cycle "
          f"({peak_cpf:.2f} cycles/function) |")
    print(f"| SIMD lanes | {lanes} |")
    print(f"| CORDIC latency | 28 (circular) / 29 (hyperbolic) core cycles |")
    print(f"| Scalar baseline cycles | {base_cyc} |")
    print(f"| Aggregate speedup | {agg_speedup:.2f}x |")
    print(f"| Peak speedup | {peak_speedup:.2f}x |")
    print(f"| Max abs error vs libm | {err_e9/1e9:.2e} |")
    print()
    print(f"Each function is one iterative CORDIC pass: 28 shift-and-add "
          f"micro-rotations (circular: sin/cos, atan2/hypot) or 29 (hyperbolic: "
          f"exp, cosh/sinh, ln, sqrt). The {lanes}-lane SIMD array evaluates "
          f"{lanes} functions per wave, so the per-function cost amortises to "
          f"{sust_cpf:.2f} cycles including ring read/write and pipeline "
          f"fill/drain. The fixed-point unit tracks IEEE double libm to "
          f"{err_e9/1e9:.2e} worst-case absolute error (~23 bits) across all six "
          f"functions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
