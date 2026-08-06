#!/usr/bin/env python3
"""Turn results/sim.log plus the cost-model totals into results/metrics.md.

Every hardware number is parsed out of the simulation log; every baseline number
comes from sw_metrics.txt, which kds_host.c wrote by running the cost model.
Nothing here is estimated - if a value is not in one of those two files it does
not appear in the table.
"""
import re
import sys


def parse_log(path):
    d = {}
    txt = open(path).read()

    def grab(pat, key, cast=int, group=1):
        m = re.search(pat, txt)
        if m:
            d[key] = cast(m.group(group))

    grab(r"scoreboard (\d+) nodes", "max_nodes")
    grab(r"scoreboard \d+ nodes, (\d+) devices", "devices")
    grab(r"(\d+) words/node record", "node_words")
    grab(r"graphs per pass\s*:\s*(\d+)", "graphs")
    grab(r"graphs per pass\s*:\s*\d+ \((\d+) clean", "clean")
    grab(r"graphs per pass\s*:\s*\d+ \(\d+ clean, (\d+) error", "errors")
    grab(r"nodes scheduled / pass\s*:\s*(\d+)", "nodes")
    grab(r"scheduler ticks / pass\s*:\s*(\d+)", "ticks")
    grab(r"serial ticks / pass\s*:\s*(\d+)", "serial")
    grab(r"engine cycles \(full rate, START to IRQ\): (\d+)", "hw_cycles")
    grab(r"wait-state pass total cycles\s*:\s*(\d+)", "ws_cycles")
    grab(r"full-rate pass total cycles\s*:\s*(\d+)", "fr_cycles")
    grab(r"bus stall cycles \(wait-state pass\)\s*:\s*(\d+)", "ws_stalls")
    grab(r"bus phase cycles \(fetch \+ writeback\)\s*:\s*(\d+)", "bus_cycles")
    grab(r"bus words \(fetch / writeback\)\s*:\s*(\d+) / (\d+)", "fetchw")
    grab(r"bus words \(fetch / writeback\)\s*:\s*\d+ / (\d+)", "wbw")
    grab(r"single-node graph latency\s*:\s*(\d+)", "latency")
    grab(r"peak graph cycles / ticks / dispatched\s*:\s*(\d+)", "peak_cycles")
    grab(r"peak graph cycles / ticks / dispatched\s*:\s*\d+ / (\d+)", "peak_ticks")
    grab(r"peak graph cycles / ticks / dispatched\s*:\s*\d+ / \d+ / (\d+)",
         "peak_disp")
    grab(r"checks\s*:\s*(\d+)", "checks")
    grab(r"mismatches\s*:\s*(\d+)", "mismatches")
    d["passed"] = "TEST PASSED" in txt
    d["memw"] = 0
    m = re.search(r"memory image (\d+) words", txt)
    if m:
        d["memw"] = int(m.group(1))
    m = re.search(r"full-memory sweep over (\d+) words", txt)
    if m:
        d["sweepw"] = int(m.group(1))
    return d


def parse_sw(path):
    d = {}
    for line in open(path):
        p = line.split()
        if len(p) == 2:
            d[p[0]] = int(p[1])
    return d


def main():
    log = parse_log(sys.argv[1])
    sw = parse_sw(sys.argv[2])

    hw = log["hw_cycles"]
    base = sw["baseline_cycles"]
    peak_hw = log["peak_cycles"]
    peak_base = sw["peak_baseline_cycles"]

    print("# Measured results")
    print()
    print("All hardware figures are read straight from the Icarus run "
          "(`results/sim.log`); the baseline is the documented cost model in "
          "`sw/kds_baseline.c`.")
    print()
    print("| metric | value |")
    print("|---|---|")
    print(f"| geometry (scoreboard nodes / devices / words per node record) | "
          f"{log['max_nodes']} / {log['devices']} / {log['node_words']} |")
    print(f"| graph launches / pass | {log['graphs']} "
          f"({log['clean']} clean + {log['errors']} rejected) |")
    print(f"| kernel nodes scheduled / pass | {log['nodes']} |")
    print(f"| scheduler ticks / pass | {log['ticks']} |")
    print(f"| serial ticks the schedule was compressed from | {log['serial']} |")
    print(f"| graph words fetched / result words written | {log['fetchw']} / "
          f"{log['wbw']} |")
    print(f"| checks | {log['checks']} |")
    print(f"| mismatches | {log['mismatches']} |")
    print(f"| engine cycles, full rate (START to interrupt) | {hw} |")
    print(f"| wait-state pass cycles | {log['ws_cycles']} "
          f"({log['ws_stalls']} injected bus stall cycles) |")
    print(f"| full-rate pass cycles | {log['fr_cycles']} |")
    print(f"| bus-phase cycles (fetch + writeback) | {log['bus_cycles']} |")
    words = log["fetchw"] + log["wbw"]
    print(f"| **AXI4-Lite occupancy in the bus phases** | "
          f"**{100.0*words/log['bus_cycles']:.1f}%** "
          f"({words/log['bus_cycles']:.3f} words/clock) |")
    print(f"| single-node graph latency (START to interrupt) | "
          f"{log['latency']} cycles |")
    print(f"| **peak dispatch rate** (peak graph: {log['peak_disp']} independent "
          f"nodes) | **{log['peak_disp']/log['peak_ticks']:.3f} nodes/clock** "
          f"(roofline 1.000) |")
    print(f"| sustained dispatch rate over all graphs | "
          f"{log['nodes']/log['ticks']:.3f} nodes/clock |")
    print(f"| **parallel compression** (serial ticks / scheduler ticks) | "
          f"**{log['serial']/log['ticks']:.3f}x** (roofline "
          f"{log['devices']}.000x) |")
    print(f"| scalar baseline (cost model) | {base} cycles |")
    print(f"| **aggregate speedup** | **{base/hw:.2f}x** |")
    print(f"| **peak speedup** | **{peak_base/peak_hw:.2f}x** |")
    print()
    print(f"Cost-model terms (cycles per modelled scalar operation): graph word "
          f"load {sw['cost_load']}, one node visited in a readiness scan "
          f"{sw['cost_scan_node']}, one device completion poll "
          f"{sw['cost_poll_dev']}, one kernel launch {sw['cost_launch']} - "
          f"evaluated over {sw['baseline_ops_load']} loads, "
          f"{sw['baseline_ops_scan']} scan visits, {sw['baseline_ops_poll']} "
          f"polls and {sw['baseline_ops_launch']} launches. The same model "
          f"reports {sw['baseline_idle_dev_ticks']} device-ticks lost to the CPU "
          f"holding the scheduling decision.")
    print()
    print(f"The full-memory sweep compares all {log.get('sweepw', 0)} words of "
          f"the simulated shared memory against the golden image after each "
          f"pass, so a write anywhere outside a result region fails the run.")
    print()
    print("TEST PASSED" if log["passed"] else "TEST FAILED")


if __name__ == "__main__":
    main()
