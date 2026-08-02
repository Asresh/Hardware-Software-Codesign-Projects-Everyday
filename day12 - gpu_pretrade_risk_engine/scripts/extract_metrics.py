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

    n_orders   = int(grab(r"THROUGHPUT orders=(\d+)"))
    hw_span    = int(grab(r"THROUGHPUT orders=\d+ span_cycles=(\d+)"))
    sustained  = grab(r"sustained_ops_per_clk=([\d.]+)")
    peak_ord   = int(grab(r"PEAKBENCH orders=(\d+)"))
    peak_span  = int(grab(r"PEAKBENCH orders=\d+ span_cycles=(\d+)"))
    peak_ops   = grab(r"peak_ops_per_clk=([\d.]+)")

    base_total = sw.get("baseline_total_cycles", 0.0)
    base_per   = sw.get("baseline_cycles_per_order", 0.0)
    n_accept   = int(sw.get("num_accept", 0))
    n_reject   = int(sw.get("num_reject", 0))

    agg_speedup  = base_total / hw_span if hw_span else 0.0
    hw_peak_per  = peak_span / peak_ord if peak_ord else 0.0
    peak_speedup = base_per / hw_peak_per if hw_peak_per else 0.0

    passed = "TEST PASSED" in log
    passA  = "PASSA mismatches=0" in log
    passB  = "PASSB mismatches=0" in log
    csrok  = "CSR fails=0" in log
    killok = "KILL fails=0" in log

    o = []
    o.append("# Day 12 - Pre-Trade Risk Engine - measured results\n")
    o.append("| metric | value |")
    o.append("|---|---|")
    o.append(f"| orders checked (main stream) | {n_orders} |")
    o.append(f"| accepted / rejected | {n_accept} / {n_reject} |")
    o.append(f"| ingest->decision latency | 2 cycles |")
    o.append(f"| sustained throughput | {sustained:.4f} orders/clock |")
    o.append(f"| peak throughput (1024-order burst) | {peak_ops:.4f} orders/clock |")
    o.append(f"| span, main stream | {hw_span} cycles |")
    o.append(f"| span, peak burst | {peak_span} cycles ({peak_ord} orders) |")
    o.append(f"| scalar baseline | {base_total:.0f} cycles ({base_per:.2f}/order) |")
    o.append(f"| **aggregate speedup** | **{agg_speedup:.2f}x** |")
    o.append(f"| **peak speedup** | **{peak_speedup:.2f}x** |")
    o.append(f"| Pass A (bubbles+backpressure) | {'0 mismatches' if passA else 'FAIL'} |")
    o.append(f"| Pass B (full rate) | {'0 mismatches' if passB else 'FAIL'} |")
    o.append(f"| CSR histogram check | {'OK' if csrok else 'FAIL'} |")
    o.append(f"| kill-switch / IRQ check | {'OK' if killok else 'FAIL'} |")
    o.append(f"| overall | {'PASSED' if passed else 'FAILED'} |")
    o.append("")
    print("\n".join(o))

if __name__ == "__main__":
    main()
