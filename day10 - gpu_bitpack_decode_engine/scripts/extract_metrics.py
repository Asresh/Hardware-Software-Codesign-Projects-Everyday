#!/usr/bin/env python3
# Turn the sim log + sw metrics into results/metrics.md
import sys, re

def parse_metrics(path):
    m = {}
    with open(path) as f:
        for line in f:
            mo = re.match(r'\s*METRIC\s+(\S+)\s+(.+)', line)
            if mo:
                m[mo.group(1)] = mo.group(2).strip()
    return m

def parse_kv(path):
    m = {}
    try:
        with open(path) as f:
            for line in f:
                p = line.split()
                if len(p) == 2:
                    m[p[0]] = p[1]
    except FileNotFoundError:
        pass
    return m

def main():
    simlog = sys.argv[1] if len(sys.argv) > 1 else 'results/sim.log'
    swm    = sys.argv[2] if len(sys.argv) > 2 else 'tb/vectors/sw_metrics.txt'
    m  = parse_metrics(simlog)
    sw = parse_kv(swm)

    def g(k, d='n/a'): return m.get(k, d)

    print("# Day 10 - Bit-Pack Decode Engine - measured results\n")
    print("All numbers are from the Icarus simulation of the RTL against the C golden model.\n")
    print("| Metric | Value |")
    print("|---|---|")
    print(f"| Blocks decoded | {g('total_blocks')} |")
    print(f"| Values decoded (per pass) | {g('total_values')} |")
    print(f"| Compressed ingress words | {g('total_words')} |")
    print(f"| Width range across blocks | {sw.get('min_width','?')}..{sw.get('max_width','?')} bits |")
    print(f"| Engine active cycles (full rate) | {g('hw_active_cycles')} |")
    print(f"| Wall cycles first-in..last-out (full rate) | {g('hw_wall_cycles')} |")
    print(f"| Sustained throughput (aggregate) | {g('sustained_values_per_clock')} values/clock |")
    print(f"| **Peak throughput** (width 8) | **{g('peak_values_per_clock')} values/clock** |")
    print(f"| Decode latency (first word in -> first value out) | {g('decode_latency_cycles')} cycles |")
    print(f"| Scalar baseline (documented cost model) | {g('baseline_cycles')} cycles |")
    print(f"| **Speedup (aggregate)** | **{g('speedup_aggregate')}x** |")
    print(f"| **Speedup (peak)** | **{g('speedup_peak')}x** |")
    print(f"| Mismatches vs golden | {g('mismatches')} |")
    print()
    verdict = "PASS" if g('mismatches') == '0' else "FAIL"
    print(f"Result: **{verdict}** (2 passes: randomised backpressure + full rate, plus a peak "
          "micro-benchmark and a malformed-block error test).")

if __name__ == '__main__':
    main()
