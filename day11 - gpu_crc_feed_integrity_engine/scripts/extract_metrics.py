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
    def f(k, d=0.0):
        try: return float(m.get(k))
        except (TypeError, ValueError): return d

    # sustained/peak throughput reported as milli-bytes/clock -> bytes/clock
    sustained = f('sustained_bpc_milli') / 1000.0
    peak      = f('peak_bpc_milli') / 1000.0

    base = float(sw.get('baseline_cycles', 0))
    wall = f('hw_wall_cycles')
    peak_cyc = f('peak_cycles')
    peak_bytes = f('peak_bytes')
    agg_speedup  = (base / wall) if wall else 0.0
    # peak speedup: baseline for the peak packet's bytes vs its hw wall cycles
    cpb = float(sw.get('baseline_cpb', 8))
    ovh = float(sw.get('baseline_overhead_per_pkt', 20))
    peak_base = peak_bytes * cpb + ovh
    peak_speedup = (peak_base / peak_cyc) if peak_cyc else 0.0

    print("# Day 11 - Feed-Integrity Engine - measured results\n")
    print("All numbers are from the Icarus simulation of the RTL against the "
          "C golden model.\n")
    print("| Metric | Value |")
    print("|---|---|")
    print(f"| Packets processed (per pass) | {g('total_pkts')} |")
    print(f"| Ingress beats (per pass) | {g('total_beats')} |")
    print(f"| Bytes CRC-checked (per pass) | {g('total_crc_bytes')} |")
    print(f"| Payload length range | {sw.get('min_plen','?')}..{sw.get('max_plen','?')} bytes |")
    print(f"| Engine active cycles (full rate) | {g('hw_active_cycles')} |")
    print(f"| Wall cycles first-in..last-out (full rate) | {g('hw_wall_cycles')} |")
    print(f"| Sustained throughput (aggregate) | {sustained:.3f} bytes/clock |")
    print(f"| **Peak throughput** (2 KB packet) | **{peak:.3f} bytes/clock** |")
    print(f"| Result latency (trailer in -> result out) | {g('decode_latency_cycles')} cycles |")
    print(f"| Scalar baseline (documented cost model) | {int(base)} cycles |")
    print(f"| **Speedup (aggregate)** | **{agg_speedup:.2f}x** |")
    print(f"| **Speedup (peak)** | **{peak_speedup:.2f}x** |")
    print(f"| CRC errors detected | {g('crc_errors_detected')} (injected {sw.get('crc_injected','?')}) |")
    print(f"| Sequence gaps detected | {g('seq_gaps_detected')} (injected {sw.get('gap_injected','?')}) |")
    print(f"| Records checked (2 passes + peak + malformed) | {g('records_checked')} |")
    print(f"| Mismatches vs golden | {g('mismatches')} |")
    print()
    verdict = "PASS" if g('mismatches') == '0' else "FAIL"
    print(f"Result: **{verdict}** (KAT CRC32(\"123456789\")=0xCBF43926, 2 passes: "
          "randomised ingress bubbles + full rate, a 2 KB peak micro-benchmark, "
          "and a malformed-frame error/IRQ test).")

if __name__ == '__main__':
    main()
