# Measured results

All hardware figures are read straight from the Icarus run (`results/sim.log`); the baseline is the documented cost model in `sw/sdv_baseline.c`.

| metric | value |
|---|---|
| geometry (MAX_NODES / MAX_DEPTH) | 64 / 16 |
| verification jobs per pass | 333 (33 directed, 300 randomised) |
| draft-tree nodes streamed in per pass | 10654 |
| egress beats out per pass | 1050 (717 accepted tokens + 333 trailers) |
| jobs rejected / clamped at the cap | 8 / 44 |
| **checks** | **10772** |
| **mismatches** | **0** |
| pass A cycles (ingress bubbles + egress backpressure) | 22084 |
| pass B cycles (back to back at full rate) | 14685 |
| engine busy cycles, full rate | 12030 |
| cycles starved by the draft link / by egress backpressure | 0 / 29 |
| minimum job latency (first beat to trailer) | 4 cycles |
| peak job (64-node chain) | 83 cycles = 64 LOAD + 1 CHECK + 17 WALK + 1 TRAIL, 16 tokens accepted |
| ingress rate during LOAD | 1.000 nodes/clock (roofline 1.000, one node record per beat) |
| **peak node rate over the whole job** | **0.771 nodes/clock** (64 nodes in 83 cycles) |
| **accepted-token rate through the walk** | **0.941 tokens/clock** (16 tokens in 17 walk cycles, roofline 1.000) |
| sustained node rate over all jobs, full rate | 0.726 nodes/clock |
| sustained node rate while busy | 0.886 nodes/clock |
| scalar baseline (cost model) | 153276 cycles |
| **aggregate speedup** (whole pass, wall clock) | **10.44x** (153276 vs 14685 cycles) |
| aggregate speedup against engine-busy cycles | 12.74x |
| **peak speedup** (peak job alone) | **22.55x** (1872 vs 83 cycles) |

The cost model in `sw/sdv_baseline.c` charges the CPU 1 cycle per 32-bit word loaded, 1 per node examined in a path-step sweep, 2 per acceptance predicate evaluated, 3 per relative-threshold multiply, 1 per result word stored and 12 per job of call overhead - evaluated over 42616 words loaded, 34204 node visits, 32567 predicate evaluations, 1042 multiplies and 4200 stores. One cycle per examined node is optimistic for a dependent pointer chase, so the speedups above are lower bounds.

The sweep that matters is the one that is *not* in this table: pass A runs every job under randomised ingress bubbles and randomised egress backpressure, pass B runs the same jobs back to back at full rate, and both are required to produce byte-identical egress beats and identical counters. The engine's 717 accepted tokens, 8 rejections and 44 clamps are therefore a function of the draft trees alone and not of link timing.

Analytical hardware cycle count over the whole pass, load + 1 + (accepted + 1) + 1 per job: 12370 cycles, against 12030 measured busy cycles.

TEST PASSED
