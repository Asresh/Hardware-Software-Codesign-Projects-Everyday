#!/usr/bin/env python3
"""Turn results/sim.log + tb/vectors/sw_metrics.txt into results/metrics.md.

Every number printed here is read back from the run; nothing is asserted by hand.
"""
import re
import sys


def parse_met(path):
    met = {}
    with open(path) as f:
        for line in f:
            m = re.match(r"^MET (\S+) (-?\d+)\s*$", line)
            if m:
                met[m.group(1)] = int(m.group(2))
    return met


def parse_sw(path):
    sw = {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2:
                try:
                    sw[parts[0]] = int(parts[1])
                except ValueError:
                    pass
    return sw


def main():
    if len(sys.argv) != 3:
        print("usage: extract_metrics.py results/sim.log tb/vectors/sw_metrics.txt")
        return 1
    met = parse_met(sys.argv[1])
    sw = parse_sw(sys.argv[2])

    cyc = met["fullrate_cycles"]
    xl = sw["tot_xlates"]
    res = sw["tot_results"]
    base = sw["baseline_cycles"]
    peak_c = met["peak_batch_cycles"]
    peak_x = met["peak_batch_xlates"]
    peak_base = sw["baseline_peak_cycles"]
    xacts = met["bus_xacts"]

    rows = [
        ("batches / pass", met["batches"]),
        ("request words / pass", sw["tot_reqs"]),
        ("translations / pass", xl),
        ("served from the translation cache", f"{sw['tot_hits']} "
         f"({100.0*sw['tot_hits']/xl:.1f}%)"),
        ("block-table walks", sw["tot_misses"]),
        ("physical blocks allocated / returned",
         f"{sw['tot_allocs']} / {sw['tot_frees']}"),
        ("result words written / pass", res),
        ("checks", met["checks"]),
        ("mismatches", met["mismatches"]),
        ("full-rate cycles (aggregate)", cyc),
        ("wait-state pass cycles (aggregate)",
         f"{met['bubble_cycles']} ({met['stall_cycles']} memory stall cycles)"),
        ("Wishbone transactions (full rate)",
         f"{xacts} ({100.0*xacts/cyc:.1f}% bus occupancy)"),
        ("sustained throughput", f"{xl/cyc:.4f} translations/clock"),
        ("sustained throughput", f"{res/cyc:.4f} result words/clock"),
        ("peak throughput (batch %d, fully cached)" % met["peak_batch_index"],
         f"{peak_x/peak_c:.4f} translations/clock ({peak_x} in {peak_c} cycles)"),
        ("single-translation latency (start -> done)",
         f"{met['latency_cycles']} cycles"),
        ("scalar baseline (cost model)", f"{base} cycles"),
        ("**aggregate speedup**", f"**{base/cyc:.2f}x**"),
        ("**peak speedup**", f"**{peak_base/peak_c:.2f}x**"),
    ]

    print("# Measured results")
    print()
    print("All hardware figures are read straight from the Icarus run "
          "(`results/sim.log`); the baseline is the documented scalar cost model "
          "in `sw/kvp_baseline.c`.")
    print()
    print("| metric | value |")
    print("|---|---|")
    for k, v in rows:
        print(f"| {k} | {v} |")
    print()
    print("Cost-model terms (cycles per modelled operation, one op per cycle): "
          f"request decode {sw['baseline_c_req']}, cached translation "
          f"{sw['baseline_c_hit']}, block-table walk {sw['baseline_c_miss']}, "
          f"walk + allocate {sw['baseline_c_alloc']}, block release "
          f"{sw['baseline_c_freeblk']}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
