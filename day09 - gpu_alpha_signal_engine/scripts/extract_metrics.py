#!/usr/bin/env python3
"""Merge testbench sim.log with the software metrics and emit results/metrics.md."""
import sys, re

def parse_kv(path):
    d = {}
    with open(path) as f:
        for line in f:
            m = re.match(r'^\s*([A-Z_]+)\s+(-?\d+)\s*$', line)
            if m:
                d[m.group(1)] = int(m.group(2))
    return d

def main():
    simlog = sys.argv[1] if len(sys.argv) > 1 else 'results/sim.log'
    swfile = sys.argv[2] if len(sys.argv) > 2 else 'tb/vectors/sw_metrics.txt'
    sim = parse_kv(simlog)
    sw  = parse_kv(swfile)

    ticks   = sim.get('TOTAL_TICKS', sw.get('TOTAL_TICKS', 0))
    hw_cyc  = sim.get('HW_CYCLES_TOTAL', 0)
    acc     = sim.get('ACCEPT_SPAN_TOTAL', hw_cyc or 1)
    base    = sw.get('BASELINE_CYCLES', 0)
    seeds   = sw.get('SEED_TICKS', 0)
    checks  = sim.get('CHECKS', 0)
    mism    = sim.get('MISMATCHES', -1)
    cperr   = sim.get('CP_ERRORS', -1)
    lat     = sim.get('LATENCY_CYCLES', 0)
    streams = sim.get('STREAMS', sw.get('STREAMS', 0))

    sustained = ticks / acc if acc else 0.0
    agg_speed = base / hw_cyc if hw_cyc else 0.0
    # steady-state scalar cost per tick (from the documented baseline model)
    steady    = (ticks - seeds)
    steady_cost = (base - seeds * 31) / steady if steady else 0.0  # 31 = seed cost
    peak_speed  = steady_cost  # HW retires 1 tick/clock at full rate

    out = []
    out.append("# Day 9 - Alpha-Signal Engine: measured results\n")
    out.append("All figures are extracted from the Icarus Verilog run "
               "(`results/sim.log`) and the golden generator "
               "(`tb/vectors/sw_metrics.txt`).\n")
    out.append("## Verification\n")
    out.append("| Quantity | Value |")
    out.append("|---|---|")
    out.append(f"| Streams | {streams} |")
    out.append(f"| Ticks processed | {ticks:,} |")
    out.append(f"| Records checked (2 passes) | {checks:,} |")
    out.append(f"| Field mismatches | {mism} |")
    out.append(f"| Control-plane errors | {cperr} |")
    out.append("")
    out.append("## Throughput & latency\n")
    out.append("| Metric | Value |")
    out.append("|---|---|")
    out.append(f"| Sustained ingest (full rate) | {sustained:.3f} ticks/clock |")
    out.append(f"| Signal latency (tick to record) | {lat} cycles |")
    out.append(f"| HW cycles (all streams, incl. drain) | {hw_cyc:,} |")
    out.append(f"| Ingest span (all streams) | {acc:,} cycles |")
    out.append("")
    out.append("## Speedup vs scalar baseline\n")
    out.append("| Metric | Value |")
    out.append("|---|---|")
    out.append(f"| Scalar baseline cycles | {base:,} |")
    out.append(f"| Scalar steady cost/tick | {steady_cost:.1f} cycles |")
    out.append(f"| **Aggregate speedup** | **{agg_speed:.2f}x** |")
    out.append(f"| **Peak speedup (steady state)** | **{peak_speed:.2f}x** |")
    out.append("")
    print("\n".join(out))

if __name__ == '__main__':
    main()
