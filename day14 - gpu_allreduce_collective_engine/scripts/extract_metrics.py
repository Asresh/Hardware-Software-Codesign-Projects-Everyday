#!/usr/bin/env python3
"""Combine the simulation log with the software metrics into results/metrics.md."""
import re, sys

def main():
    sim_log = sys.argv[1] if len(sys.argv) > 1 else "results/sim.log"
    sw_txt  = sys.argv[2] if len(sys.argv) > 2 else "tb/vectors/sw_metrics.txt"

    log = open(sim_log).read()
    sw  = {}
    for line in open(sw_txt):
        parts = line.split()
        if len(parts) == 2:
            try:    sw[parts[0]] = float(parts[1])
            except ValueError: pass

    def grab(pat, default=0.0):
        m = re.search(pat, log)
        return float(m.group(1)) if m else default

    words      = int(grab(r"THROUGHPUT words=(\d+)"))
    span_full  = int(grab(r"THROUGHPUT words=\d+ span_cycles=(\d+)"))
    sustained  = grab(r"sustained_ops_per_clk=([\d.]+)")
    peak_words = int(grab(r"PEAKBENCH words=(\d+)"))
    peak_span  = int(grab(r"PEAKBENCH words=\d+ span_cycles=(\d+)"))
    peak_ops   = grab(r"peak_ops_per_clk=([\d.]+)")
    latency    = int(grab(r"LATENCY cycles=(\d+)"))

    base_total = sw.get("baseline_total_cycles", 0.0)
    base_peak  = sw.get("baseline_peak_cycles", 0.0)
    per_elem   = sw.get("baseline_cycles_per_element", 0.0)
    n_desc     = int(sw.get("num_desc", 0))
    n_elems    = int(sw.get("total_elements", 0))
    n_groups   = int(sw.get("total_groups", 0))

    agg_speedup  = base_total / span_full if span_full else 0.0
    peak_speedup = base_peak  / peak_span if peak_span else 0.0

    passed = "TEST PASSED" in log
    passA  = "PASSA mismatches=0" in log
    passB  = "PASSB mismatches=0" in log
    peakok = "PEAK mismatches=0"  in log
    csrok  = "CSR fails=0" in log
    irqok  = "IRQ fails=0" in log

    o = []
    o.append("# Day 14 - GPU All-Reduce Collective Engine - measured results\n")
    o.append("| metric | value |")
    o.append("|---|---|")
    o.append(f"| collectives (descriptors) / pass | {n_desc} |")
    o.append(f"| elements reduced / groups | {n_elems} / {n_groups} |")
    o.append(f"| gather->scatter latency | {latency} cycles |")
    o.append(f"| sustained throughput | {sustained:.4f} words/clock |")
    o.append(f"| peak throughput (single big collective) | {peak_ops:.4f} words/clock |")
    o.append(f"| span, full ring | {span_full} cycles ({words} words) |")
    o.append(f"| span, peak collective | {peak_span} cycles ({peak_words} words) |")
    o.append(f"| scalar baseline | {base_total:.0f} cycles ({per_elem:.0f}/element) |")
    o.append(f"| **aggregate speedup** | **{agg_speedup:.2f}x** |")
    o.append(f"| **peak speedup** | **{peak_speedup:.2f}x** |")
    o.append(f"| Pass A (memory wait states) | {'0 mismatches' if passA else 'FAIL'} |")
    o.append(f"| Pass B (full rate) | {'0 mismatches' if passB else 'FAIL'} |")
    o.append(f"| Peak (descriptor 0 alone) | {'0 mismatches' if peakok else 'FAIL'} |")
    o.append(f"| CSR statistics check | {'OK' if csrok else 'FAIL'} |")
    o.append(f"| error / IRQ check | {'OK' if irqok else 'FAIL'} |")
    o.append(f"| overall | {'PASSED' if passed else 'FAILED'} |")
    o.append("")
    print("\n".join(o))

if __name__ == "__main__":
    main()
