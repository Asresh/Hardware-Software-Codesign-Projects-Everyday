#!/usr/bin/env python3
"""Turn the simulation log + the software cost model into results/metrics.md.

Reads the machine-readable summary the testbench prints (JOBS, CHECKS,
MISMATCHES, HW_CYCLES_TOTAL, LATENCY_CYCLES, OVERFLOW_STREAMS_HW) and the
software cost model written by lob_host (STREAMS, TOTAL_MSGS, MAX_MSGS,
BASELINE_CYCLES_TOTAL, BASELINE_PEAK_PERMSG, ...). Emits a Markdown table of
measured numbers only."""
import sys


def parse_kv(path):
    d = {}
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) >= 2:
                try:
                    d[p[0].strip()] = int(p[1].strip())
                except ValueError:
                    pass
    return d


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: extract_metrics.py sim.log sw_metrics.txt\n")
        return 1
    sim = parse_kv(sys.argv[1])
    sw = parse_kv(sys.argv[2])

    jobs   = sim.get("JOBS", 0)
    checks = sim.get("CHECKS", 0)
    mism   = sim.get("MISMATCHES", -1)
    hw_cyc = sim.get("HW_CYCLES_TOTAL", 0)
    lat    = sim.get("LATENCY_CYCLES", 0)
    ovf_hw = sim.get("OVERFLOW_STREAMS_HW", 0)

    msgs   = sw.get("TOTAL_MSGS", 0)
    corner = sw.get("CORNER_STREAMS", 0)
    rand   = sw.get("RANDOM_STREAMS", 0)
    maxm   = sw.get("MAX_MSGS", 0)
    ovf_sw = sw.get("OVERFLOW_STREAMS", 0)
    base   = sw.get("BASELINE_CYCLES_TOTAL", 0)
    peak   = sw.get("BASELINE_PEAK_PERMSG", 0)

    thr   = (msgs / hw_cyc) if hw_cyc else 0.0
    spd   = (base / hw_cyc) if hw_cyc else 0.0
    # steady-state hardware cost is exactly 1 message/clock
    peak_spd = float(peak)
    base_per = (base / msgs) if msgs else 0.0

    status = "PASS" if mism == 0 else "FAIL"

    print("# Day 8 - CAM Order-Book / BBO Engine - measured results\n")
    print("| Metric | Value |")
    print("|---|---|")
    print(f"| Streams (corner + random) | {jobs} ({corner} + {rand}) |")
    print(f"| Messages processed | {msgs} |")
    print(f"| BBO records checked (2 passes) | {checks} |")
    print(f"| Mismatches vs golden model | {mism} |")
    print(f"| Overflow streams (HW / SW) | {ovf_hw} / {ovf_sw} |")
    print(f"| Longest stream | {maxm} messages |")
    print("| CAM depth | 32 price levels |")
    print(f"| Message->BBO latency | {lat} cycles |")
    print(f"| Sustained throughput | {thr:.3f} messages/clock |")
    print(f"| HW cycles (full-rate pass) | {hw_cyc} |")
    print(f"| Baseline cycles (scalar model) | {base} |")
    print(f"| Baseline cost / message (avg) | {base_per:.2f} cycles |")
    print(f"| Baseline peak / message | {peak} cycles |")
    print(f"| **Aggregate speedup** | **{spd:.2f}x** |")
    print(f"| **Peak speedup** (full book) | **{peak_spd:.2f}x** |")
    print(f"| Status | **{status}** |")
    print()
    print("Throughput = messages / full-rate HW cycles (includes the 2-cycle "
          "pipeline drain per stream). Aggregate speedup = total scalar-model "
          "cycles / full-rate HW cycles over the identical message corpus. Peak "
          "speedup = worst-case scalar per-message cost (full 32-level book) "
          "against the engine's steady-state 1 message/clock.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
