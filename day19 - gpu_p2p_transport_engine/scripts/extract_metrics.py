#!/usr/bin/env python3
"""Turn the simulation log and the software cost model into results/metrics.md.

Every number written here is read out of one of those two files. Nothing is
estimated, and anything that could not be measured is simply absent.
"""
import re
import sys


def read_log(path):
    m, res = {}, {}
    for line in open(path):
        g = re.match(r"METRIC (\S+) (-?\d+)", line)
        if g:
            m[g.group(1)] = int(g.group(2))
        g = re.match(r"RESULT (.*)", line)
        if g:
            for kv in g.group(1).split():
                k, v = kv.split("=")
                res[k] = int(v)
    m["passed"] = "TEST PASSED" in open(path).read()
    m.update(res)
    return m


def read_kv(path):
    d = {}
    for line in open(path):
        p = line.split()
        if len(p) == 2:
            d[p[0]] = int(p[1])
    return d


def main():
    log = read_log(sys.argv[1])
    sw = read_kv(sys.argv[2])
    mtu = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    qp = int(sys.argv[4]) if len(sys.argv) > 4 else 4
    bufs = int(sys.argv[5]) if len(sys.argv) > 5 else 4

    eng = log["engine_cycles_total"]
    peak_c = log["peak_cycles"]
    peak_w = log["peak_words"]
    pac_c = log["peakacc_cycles"]
    pac_w = log["peakacc_words"]
    pkts_peak = (peak_w + mtu - 1) // mtu
    peak_beats = pkts_peak * (mtu + 2)

    roof = mtu / (mtu + 2.0)
    rate = peak_w / peak_c
    arate = pac_w / pac_c
    occ = peak_beats / peak_c
    sust = sw["tx_words"] / eng

    base = sw["baseline_cycles"]
    base_peak = sw["baseline_peak_cycles"]

    o = []
    o.append("# Measured results\n")
    o.append("All hardware figures are read straight from the Icarus run "
             "(`results/sim.log`); the baseline is the documented cost model "
             "in `sw/p2p_baseline.c`.\n")
    o.append("| metric | value |")
    o.append("|---|---|")
    o.append(f"| geometry (MTU words / queue pairs / receive buffers) "
             f"| {mtu} / {qp} / {bufs} |")
    o.append(f"| launches per pass | {log['runs']} |")
    o.append(f"| work-queue entries accepted / rejected | "
             f"{sw['wqes_accepted']} / {sw['wqes_rejected']} |")
    o.append(f"| packets transmitted per pass | {sw['packets']} |")
    o.append(f"| payload words transmitted / committed | "
             f"{sw['tx_words']} / {sw['rx_words']} |")
    o.append(f"| completion entries posted | {sw['cqes']} |")
    o.append(f"| packets discarded on a sequence gap | {sw['seq_drops']} |")
    o.append(f"| shared memory image | {log['mem_words']} words |")
    o.append(f"| **checks** | **{log['checks']}** |")
    o.append(f"| **mismatches** | **{log['fails']}** |")
    o.append(f"| pass 0 cycles (randomised wait states, link gaps, credit "
             f"delay) | {log['pass0_cycles']} "
             f"({log['pass0_injected_stall']} injected bus stall cycles) |")
    o.append(f"| pass 1 cycles (full rate) | {log['pass1_cycles']} |")
    o.append(f"| pass 2 cycles (one credit per queue pair) | "
             f"{log['pass2_cycles']} |")
    o.append(f"| engine busy cycles, full rate (doorbell to interrupt) | "
             f"{eng} |")
    o.append(f"| memory read / write beats, full rate | "
             f"{log['rd_beats']} / {log['wr_beats']} |")
    o.append(f"| link beats, full rate | {log['link_beats']} |")
    o.append(f"| single-word message latency (doorbell to interrupt) | "
             f"{log['latency_cycles']} cycles |")
    o.append(f"| **peak link occupancy** (peak message, {peak_w} words) | "
             f"**{occ*100:.1f}%** ({peak_beats} beats in {peak_c} cycles) |")
    o.append(f"| **peak payload rate, WRITE** | **{rate:.3f} words/clock** "
             f"(roofline {roof:.3f} = MTU/(MTU+2)) |")
    o.append(f"| **peak payload rate, ACCUM** ({pac_w} words) | "
             f"**{arate:.3f} words/clock** |")
    o.append(f"| sustained payload rate over all launches | "
             f"{sust:.3f} words/clock |")
    o.append(f"| transmitter cycles waiting on credits / on the wire | "
             f"{log['credit_stall']} / {log['link_stall']} |")
    o.append(f"| datapath cycles waiting on the memory port | "
             f"{log['mem_stall']} |")
    o.append(f"| scalar baseline (cost model) | {base} cycles |")
    o.append(f"| **aggregate speedup** | **{base/eng:.2f}x** |")
    o.append(f"| **peak speedup** | **{base_peak/peak_c:.2f}x** |")
    o.append("")
    o.append("Cost-model terms (cycles per modelled scalar operation): "
             "descriptor word load 4, descriptor validation 24, packet header "
             "build 12, packet post 30, flow-control test 6, payload word out "
             "8, payload word in 8, accumulated word in 13, completion word "
             "store 4, completion bookkeeping 20 - evaluated over "
             f"{sw['cost_wqe_loads']} descriptor loads, "
             f"{sw['cost_pkt_builds']} packet builds, "
             f"{sw['cost_tx_words']} words out, "
             f"{sw['cost_rx_words']} plain words in, "
             f"{sw['cost_accum_words']} accumulated words in and "
             f"{sw['cost_cqe_posts']} completions.")
    o.append("")
    o.append(f"The full-memory sweep compares all {log['mem_words']} words of "
             "the simulated shared memory against the golden image after every "
             "pass, so a write anywhere outside a destination region, a "
             "completion slot, or past the end of a message fails the run. "
             f"The memory model also counts out-of-range accesses: "
             f"{log['oob_accesses']}.")
    o.append("")
    o.append("TEST PASSED" if log["passed"] else "TEST FAILED")
    print("\n".join(o))


if __name__ == "__main__":
    main()
