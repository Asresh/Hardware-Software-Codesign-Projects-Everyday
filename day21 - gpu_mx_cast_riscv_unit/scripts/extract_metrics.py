#!/usr/bin/env python3
"""Turn the simulation log and the generator's own totals into results/metrics.md.

Every number here is read out of a run - there is nothing analytical in this
file. The speedups are cycle ratios between two programs that ran on the same
hardware over the same data, which is why they are quoted per block rather than
per job: the base kernels only run on a subset, and comparing totals across
different subsets would be meaningless."""
import re
import sys


def read_kv(path):
    out = {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            if parts[0] in ("jobs", "commits", "trace_entries", "blk",
                            "host_checks"):
                out[parts[0]] = int(parts[1])
            elif parts[0] in ("quant_custom", "quant_base", "dequant_custom",
                              "dequant_base"):
                d = {}
                for i in range(1, len(parts) - 1, 2):
                    d[parts[i]] = int(parts[i + 1])
                out[parts[0]] = d
            elif parts[0] == "paired":
                d = {}
                for i in range(1, len(parts) - 1, 2):
                    d[parts[i]] = int(parts[i + 1])
                out["paired"] = d
            elif parts[0] == "imem_words":
                d = {}
                for i in range(1, len(parts) - 1, 2):
                    d[parts[i]] = int(parts[i + 1])
                out["imem_words"] = d
    return out


def main():
    simlog, swfile = sys.argv[1], sys.argv[2]
    imem_w, dmem_w, blk = (int(x) for x in sys.argv[3:6])

    log = open(simlog).read()
    sw = read_kv(swfile)

    m = re.search(r"RESULT jobs=(\d+) checks=(\d+) fails=(\d+) commits=(\d+) "
                  r"mem=(\d+) sweep=(\d+)", log)
    if not m:
        sys.exit("no RESULT line in " + simlog)
    jobs, checks, fails, commits, mem, sweep = (int(x) for x in m.groups())

    p = sw["paired"]
    pb = p["blocks"]
    qc, qb = p["qc_cycles"], p["qb_cycles"]
    dc, db = p["dc_cycles"], p["db_cycles"]
    qci, qbi = p["qc_instr"], p["qb_instr"]
    dci, dbi = p["dc_instr"], p["db_instr"]

    all_c = sw["quant_custom"]
    all_d = sw["dequant_custom"]

    def r(a, b):
        return b / a if a else 0.0

    print("# Day 21 - measured results\n")
    print("Geometry: instruction memory 2^%d words, data memory 2^%d words, "
          "MX block %d elements.\n" % (imem_w, dmem_w, blk))

    print("## Verification\n")
    print("| quantity | value |")
    print("|---|---|")
    print("| jobs run (two passes plus recovery) | %d |" % jobs)
    print("| checks | %d |" % checks)
    print("| mismatches | %d |" % fails)
    print("| instruction commits compared against the simulator | %d |" % commits)
    print("| data-memory words compared | %d |" % mem)
    print("| full-memory sweep words | %d |" % sweep)
    print("| output words compared against the C model by the host | %d |"
          % sw.get("host_checks", 0))
    print()

    print("## Cast throughput, measured on the core\n")
    print("Both versions of each kernel ran over the same %d blocks "
          "(%d elements).\n" % (pb, pb * blk))
    print("| kernel | cycles/block | instructions/block | cycles/element |")
    print("|---|---|---|---|")
    print("| quantise, custom-0 | %.1f | %.1f | %.2f |"
          % (qc / pb, qci / pb, qc / (pb * blk)))
    print("| quantise, base RV32I | %.1f | %.1f | %.2f |"
          % (qb / pb, qbi / pb, qb / (pb * blk)))
    print("| dequantise, custom-0 | %.1f | %.1f | %.2f |"
          % (dc / pb, dci / pb, dc / (pb * blk)))
    print("| dequantise, base RV32I | %.1f | %.1f | %.2f |"
          % (db / pb, dbi / pb, db / (pb * blk)))
    print()

    print("## Speedup\n")
    print("| kernel | cycles | instructions |")
    print("|---|---|---|")
    print("| quantise | %.2fx | %.2fx |" % (r(qc, qb), r(qci, qbi)))
    print("| dequantise | %.2fx | %.2fx |" % (r(dc, db), r(dci, dbi)))
    print("| round trip | %.2fx | %.2fx |"
          % (r(qc + dc, qb + db), r(qci + dci, qbi + dbi)))
    print()

    print("## Whole experiment\n")
    print("| kernel | jobs | blocks | elements | cycles | instructions | "
          "custom-0 ops |")
    print("|---|---|---|---|---|---|---|")
    for k in ("quant_custom", "quant_base", "dequant_custom", "dequant_base"):
        d = sw[k]
        print("| %s | %d | %d | %d | %d | %d | %d |"
              % (k.replace("_", " "), d["jobs"], d["blocks"], d["elems"],
                 d["cycles"], d["instret"], d["custom"]))
    print()

    ipc_c = all_c["instret"] / all_c["cycles"] if all_c["cycles"] else 0
    ipc_d = all_d["instret"] / all_d["cycles"] if all_d["cycles"] else 0
    print("## Pipeline\n")
    print("| quantity | value |")
    print("|---|---|")
    print("| instructions per cycle, quantise with custom-0 | %.3f |" % ipc_c)
    print("| instructions per cycle, dequantise with custom-0 | %.3f |" % ipc_d)
    print("| custom-0 instructions per element, quantise | %.3f |"
          % (all_c["custom"] / all_c["elems"]))
    print("| custom-0 instructions per element, dequantise | %.3f |"
          % (all_d["custom"] / all_d["elems"]))
    print("| cycles = instret + taken branches + 2 | held on every job |")
    print()

    iw = sw["imem_words"]
    print("## Code size\n")
    print("| kernel | instruction words |")
    print("|---|---|")
    for k, v in iw.items():
        print("| %s | %d |" % (k.replace("_", " "), v))
    print()


if __name__ == "__main__":
    main()
