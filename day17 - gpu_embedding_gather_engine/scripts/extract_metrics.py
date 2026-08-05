#!/usr/bin/env python3
"""Turn results/sim.log into results/metrics.md.

Every number in the table comes from the simulation log or from the scalar
baseline cost model; nothing is estimated here.

usage: extract_metrics.py results/sim.log tb/vectors/sw_metrics.txt
"""
import re
import sys


def read_metrics(path):
    m = {}
    with open(path) as f:
        for line in f:
            mo = re.match(r"\s*METRIC\s+(\w+)\s+(-?\d+)\s*$", line)
            if mo:
                m[mo.group(1)] = int(mo.group(2))
    return m


def read_kv(path):
    kv = {}
    try:
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2:
                    kv[parts[0]] = int(parts[1])
    except OSError:
        pass
    return kv


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: extract_metrics.py sim.log [sw_metrics.txt]")
    m = read_metrics(sys.argv[1])
    kv = read_kv(sys.argv[2]) if len(sys.argv) > 2 else {}
    if not m:
        sys.exit("no METRIC lines found in " + sys.argv[1])

    passed = "TEST PASSED" in open(sys.argv[1]).read()

    dim = m["dim"]
    lanes = m["lanes"]
    chunks = m["chunks"]

    local = m["local_rows"]
    pooled_words = local * dim            # embedding words actually gathered+folded
    beats = m["read_beats"] + m["write_beats"]

    cyc_full = m["cycles_full"]
    cyc_wait = m["cycles_wait"]
    cyc_single = m["cycles_single"]
    cyc_peak = m["cycles_peak"]

    peak_words = m["peak_local_rows"] * dim
    peak_beats = m["peak_read_beats"] + m["peak_write_beats"]

    sust = pooled_words / cyc_full
    peak = peak_words / cyc_peak
    occ_full = 100.0 * beats / cyc_full
    occ_peak = 100.0 * peak_beats / cyc_peak

    base = m["baseline_cycles"]
    pbase = m["peak_baseline_cycles"]
    sp_agg = base / cyc_full
    sp_peak = pbase / cyc_peak
    dbuf = cyc_single / cyc_full

    print("# Measured results")
    print()
    print("All hardware figures are read straight from the Icarus run "
          "(`results/sim.log`); the baseline is the documented scalar cost model "
          "in `sw/emb_baseline.c`.")
    print()
    print("| metric | value |")
    print("|---|---|")
    print(f"| geometry (EMB_DIM / LANES / CHUNKS / MAX_BAG) | "
          f"{dim} / {lanes} / {chunks} / {m['max_bag']} |")
    print(f"| descriptors (bags) / pass | {m['descriptors']} "
          f"({m['directed']} directed + {m['random']} randomised) |")
    print(f"| indices examined / pass | {m['indices']} |")
    print(f"| rows gathered from the local shard | {m['local_rows']} "
          f"({100.0*m['local_rows']/m['indices']:.1f}%) |")
    print(f"| indices owned by a peer shard | {m['remote_indices']} "
          f"({100.0*m['remote_indices']/m['indices']:.1f}%) |")
    print(f"| indices past the end of the global table | {m['invalid_indices']} |")
    print(f"| bags rejected for exceeding MAX_BAG | {m['baglen_rejects']} |")
    print(f"| embedding words gathered + pooled / pass | {pooled_words} |")
    print(f"| AXI4 read beats / write beats | {m['read_beats']} / {m['write_beats']} |")
    print(f"| pooled output words written / pass | {m['output_words']} |")
    print(f"| checks | {m['checks']} |")
    print(f"| mismatches | {m['mismatches']} |")
    print(f"| full-rate cycles (aggregate) | {cyc_full} |")
    print(f"| wait-state pass cycles (aggregate) | {cyc_wait} "
          f"({cyc_wait - cyc_full} bus stall cycles) |")
    print(f"| single-buffer cycles (same results, overlap off) | {cyc_single} |")
    print(f"| AXI4 bus occupancy (full rate) | {occ_full:.1f}% |")
    print(f"| sustained throughput | {sust:.4f} pooled words/clock "
          f"(roofline {lanes}) |")
    print(f"| peak throughput (peak descriptor, {m['peak_local_rows']} local rows) | "
          f"{peak:.4f} pooled words/clock ({occ_peak:.1f}% bus occupancy) |")
    print(f"| peak cycles / row ({chunks}-beat burst) | "
          f"{cyc_peak/m['peak_local_rows']:.2f} |")
    print(f"| **double-buffering speedup** | **{dbuf:.3f}x** |")
    print(f"| scalar baseline (cost model) | {base} cycles |")
    print(f"| **aggregate speedup** | **{sp_agg:.2f}x** |")
    print(f"| **peak speedup** | **{sp_peak:.2f}x** |")
    print()
    if kv:
        print("Cost-model terms (cycles per modelled scalar operation, one op per "
              "cycle): descriptor decode 6, index classify 6, row address 4, "
              "first-row element 3, folded element 4, mean element 22 (32-bit "
              "divide), copy-out element 2, empty-bag element 2 - evaluated over "
              f"{kv.get('baseline_ops', 0)} modelled operations.")
        print()
    print("TEST PASSED" if passed else "TEST FAILED")


if __name__ == "__main__":
    main()
