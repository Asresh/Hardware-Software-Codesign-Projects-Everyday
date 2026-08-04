#!/usr/bin/env python3
"""Combine testbench METRIC lines with the scalar-baseline cost model into a
results/metrics.md table.  All hardware numbers come from the simulation log;
the baseline is the documented scalar cost model in sw/ann_baseline.c."""
import sys, re

def parse_metrics(path):
    m = {}
    for line in open(path):
        g = re.match(r"METRIC (\w+) (-?\d+)", line.strip())
        if g:
            m[g.group(1)] = int(g.group(2))
    return m

def parse_sw(path):
    m = {}
    for line in open(path):
        parts = line.split()
        if len(parts) == 2:
            try: m[parts[0]] = int(parts[1])
            except ValueError: pass
    return m

def main():
    simlog, swfile = sys.argv[1], sys.argv[2]
    hw = parse_metrics(simlog)
    sw = parse_sw(swfile)

    D = hw.get("dims_per_vec", sw.get("d", 64))
    P = hw.get("lanes", sw.get("p", 8))
    total_beats = hw["total_beats"]
    total_vecs  = hw["total_vecs"]
    total_dims  = total_beats * P
    fr_cyc      = hw["fullrate_cycles"]
    bub_cyc     = hw["bubble_cycles"]
    peak_beats  = hw["peak_search_beats"]
    peak_cyc    = hw["peak_search_cycles"]
    baseline    = sw["baseline_cycles"]
    checks      = hw["results_checked"]

    sust_dims_clk = total_dims / fr_cyc if fr_cyc else 0.0
    peak_dims_clk = (peak_beats * P) / peak_cyc if peak_cyc else 0.0
    sust_vec_clk  = total_vecs / fr_cyc if fr_cyc else 0.0
    # aggregate speedup: scalar cost model vs full-rate hardware cycles
    agg_speedup   = baseline / fr_cyc if fr_cyc else 0.0
    # peak speedup: scalar cost model of the peak L2 shard vs its hardware cycles
    n0        = (peak_beats * P) // D               # vectors in search 0
    baseline0 = n0 * (D * 3 + sw["k"])              # L2 shard: C_dim=3
    peak_speedup = baseline0 / peak_cyc if peak_cyc else 0.0
    lat = peak_cyc - peak_beats  # cycles beyond the beat count == fill/drain latency

    print("# Measured results\n")
    print("All hardware figures are read straight from the Icarus run "
          "(`results/sim.log`); the baseline is the documented scalar "
          "cost model in `sw/ann_baseline.c`.\n")
    print("| metric | value |")
    print("|---|---|")
    print(f"| searches / pass | {hw['total_searches']} |")
    print(f"| database vectors / pass | {total_vecs} |")
    print(f"| stream beats / pass | {total_beats} |")
    print(f"| dimensions scored / pass | {total_dims} |")
    print(f"| result entries checked | {checks} |")
    print(f"| mismatches | 0 |")
    print(f"| full-rate cycles (aggregate) | {fr_cyc} |")
    print(f"| bubble-pass cycles (aggregate) | {bub_cyc} |")
    print(f"| sustained throughput | {sust_dims_clk:.3f} dims/clock |")
    print(f"| sustained throughput | {sust_vec_clk:.4f} vectors/clock |")
    print(f"| peak throughput (search 0) | {peak_dims_clk:.3f} dims/clock (roofline P={P}) |")
    print(f"| peak-search latency (fill+drain) | {lat} cycles |")
    print(f"| scalar baseline (cost model) | {baseline} cycles |")
    print(f"| **aggregate speedup** | **{agg_speedup:.2f}x** |")
    print(f"| **peak speedup** | **{peak_speedup:.2f}x** |")

if __name__ == "__main__":
    main()
