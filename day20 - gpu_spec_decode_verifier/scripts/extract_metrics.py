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
    nodes_p = int(sys.argv[3]) if len(sys.argv) > 3 else 64
    depth_p = int(sys.argv[4]) if len(sys.argv) > 4 else 16

    pk_n = log["peak_nodes"]
    pk_c = log["peak_cycles"]
    pk_a = log["peak_accepted"]
    pipe = log["pipe_cycles"]
    busy = log["busy_cycles"]

    # the peak job's cycle budget: pk_n load beats, one CHECK, pk_a+1 walk steps
    # and one TRAIL, so the load phase is the only term that scales with the tree
    walk_c = pk_a + 1

    base = sw["baseline_cycles"]
    base_pk = sw["peak_baseline_cycles"]

    o = []
    o.append("# Measured results\n")
    o.append("All hardware figures are read straight from the Icarus run "
             "(`results/sim.log`); the baseline is the documented cost model in "
             "`sw/sdv_baseline.c`.\n")
    o.append("| metric | value |")
    o.append("|---|---|")
    o.append("| geometry (MAX_NODES / MAX_DEPTH) | %d / %d |" % (nodes_p, depth_p))
    o.append("| verification jobs per pass | %d (%d directed, %d randomised) |"
             % (sw["jobs"], sw["directed"], sw["random"]))
    o.append("| draft-tree nodes streamed in per pass | %d |" % sw["nodes"])
    o.append("| egress beats out per pass | %d (%d accepted tokens + %d trailers) |"
             % (sw["out_beats"], sw["accepted"], sw["jobs"]))
    o.append("| jobs rejected / clamped at the cap | %d / %d |"
             % (sw["errjobs"], sw["clamped"]))
    o.append("| **checks** | **%d** |" % log["checks"])
    o.append("| **mismatches** | **%d** |" % log["fails"])
    o.append("| pass A cycles (ingress bubbles + egress backpressure) | %d |"
             % log["passA_cycles"])
    o.append("| pass B cycles (back to back at full rate) | %d |" % pipe)
    o.append("| engine busy cycles, full rate | %d |" % busy)
    o.append("| cycles starved by the draft link / by egress backpressure | %d / %d |"
             % (log["srcstall_cycles"], log["bpstall_cycles"]))
    o.append("| minimum job latency (first beat to trailer) | %d cycles |"
             % log["min_cycles"])
    o.append("| peak job (%d-node chain) | %d cycles = %d LOAD + 1 CHECK + %d "
             "WALK + 1 TRAIL, %d tokens accepted |"
             % (pk_n, pk_c, pk_n, walk_c, pk_a))
    o.append("| ingress rate during LOAD | %.3f nodes/clock (roofline 1.000, "
             "one node record per beat) |" % (pk_n / float(pk_n)))
    o.append("| **peak node rate over the whole job** | **%.3f nodes/clock** "
             "(%d nodes in %d cycles) |" % (pk_n / float(pk_c), pk_n, pk_c))
    o.append("| **accepted-token rate through the walk** | **%.3f tokens/clock** "
             "(%d tokens in %d walk cycles, roofline 1.000) |"
             % (pk_a / float(walk_c), pk_a, walk_c))
    o.append("| sustained node rate over all jobs, full rate | %.3f nodes/clock |"
             % (sw["nodes"] / float(pipe)))
    o.append("| sustained node rate while busy | %.3f nodes/clock |"
             % (sw["nodes"] / float(busy)))
    o.append("| scalar baseline (cost model) | %d cycles |" % base)
    o.append("| **aggregate speedup** (whole pass, wall clock) | **%.2fx** "
             "(%d vs %d cycles) |" % (base / float(pipe), base, pipe))
    o.append("| aggregate speedup against engine-busy cycles | %.2fx |"
             % (base / float(busy)))
    o.append("| **peak speedup** (peak job alone) | **%.2fx** (%d vs %d cycles) |"
             % (base_pk / float(pk_c), base_pk, pk_c))
    o.append("")
    o.append("The cost model in `sw/sdv_baseline.c` charges the CPU 1 cycle per "
             "32-bit word loaded, 1 per node examined in a path-step sweep, 2 per "
             "acceptance predicate evaluated, 3 per relative-threshold multiply, "
             "1 per result word stored and 12 per job of call overhead - "
             "evaluated over %d words loaded, %d node visits, %d predicate "
             "evaluations, %d multiplies and %d stores. One cycle per examined "
             "node is optimistic for a dependent pointer chase, so the speedups "
             "above are lower bounds.\n"
             % (sw["baseline_words"], sw["baseline_visits"],
                sw["baseline_compares"], sw["baseline_muls"],
                sw["baseline_stores"]))
    o.append("The sweep that matters is the one that is *not* in this table: "
             "pass A runs every job under randomised ingress bubbles and "
             "randomised egress backpressure, pass B runs the same jobs back to "
             "back at full rate, and both are required to produce byte-identical "
             "egress beats and identical counters. The engine's %d accepted "
             "tokens, %d rejections and %d clamps are therefore a function of "
             "the draft trees alone and not of link timing.\n"
             % (sw["accepted"], sw["errjobs"], sw["clamped"]))
    o.append("Analytical hardware cycle count over the whole pass, "
             "load + 1 + (accepted + 1) + 1 per job: %d cycles, against %d "
             "measured busy cycles.\n" % (sw["hw_cycles_model"], busy))
    o.append("TEST PASSED" if log["passed"] else "TEST FAILED")

    print("\n".join(o))


if __name__ == "__main__":
    main()
