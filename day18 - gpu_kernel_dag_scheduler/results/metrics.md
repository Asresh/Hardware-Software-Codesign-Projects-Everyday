# Measured results

All hardware figures are read straight from the Icarus run (`results/sim.log`); the baseline is the documented cost model in `sw/kds_baseline.c`.

| metric | value |
|---|---|
| geometry (scoreboard nodes / devices / words per node record) | 64 / 4 / 4 |
| graph launches / pass | 326 (317 clean + 9 rejected) |
| kernel nodes scheduled / pass | 9991 |
| scheduler ticks / pass | 56632 |
| serial ticks the schedule was compressed from | 146263 |
| graph words fetched / result words written | 40092 / 39964 |
| checks | 255388 |
| mismatches | 0 |
| engine cycles, full rate (START to interrupt) | 140266 |
| wait-state pass cycles | 515157 (698152 injected bus stall cycles) |
| full-rate pass cycles | 160804 |
| bus-phase cycles (fetch + writeback) | 81349 |
| **AXI4-Lite occupancy in the bus phases** | **98.4%** (0.984 words/clock) |
| single-node graph latency (START to interrupt) | 32 cycles |
| **peak dispatch rate** (peak graph: 64 independent nodes) | **0.985 nodes/clock** (roofline 1.000) |
| sustained dispatch rate over all graphs | 0.176 nodes/clock |
| **parallel compression** (serial ticks / scheduler ticks) | **2.583x** (roofline 4.000x) |
| scalar baseline (cost model) | 2470936 cycles |
| **aggregate speedup** | **17.62x** |
| **peak speedup** | **18.37x** |

Cost-model terms (cycles per modelled scalar operation): graph word load 4, one node visited in a readiness scan 8, one device completion poll 6, one kernel launch 120 - evaluated over 39964 loads, 104823 scan visits, 45596 polls and 9991 launches. The same model reports 7098584 device-ticks lost to the CPU holding the scheduling decision.

The full-memory sweep compares all 80844 words of the simulated shared memory against the golden image after each pass, so a write anywhere outside a result region fails the run.

TEST PASSED
