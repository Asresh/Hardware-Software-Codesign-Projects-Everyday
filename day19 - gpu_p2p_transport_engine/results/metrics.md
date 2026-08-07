# Measured results

All hardware figures are read straight from the Icarus run (`results/sim.log`); the baseline is the documented cost model in `sw/p2p_baseline.c`.

| metric | value |
|---|---|
| geometry (MTU words / queue pairs / receive buffers) | 16 / 4 / 4 |
| launches per pass | 331 |
| work-queue entries accepted / rejected | 1075 / 9 |
| packets transmitted per pass | 2283 |
| payload words transmitted / committed | 28328 / 28280 |
| completion entries posted | 1074 |
| packets discarded on a sequence gap | 3 |
| shared memory image | 70656 words |
| **checks** | **221952** |
| **mismatches** | **0** |
| pass 0 cycles (randomised wait states, link gaps, credit delay) | 368142 (658904 injected bus stall cycles) |
| pass 1 cycles (full rate) | 101835 |
| pass 2 cycles (one credit per queue pair) | 118719 |
| engine busy cycles, full rate (doorbell to interrupt) | 68368 |
| memory read / write beats, full rate | 45424 / 32576 |
| link beats, full rate | 32894 |
| single-word message latency (doorbell to interrupt) | 29 cycles |
| **peak link occupancy** (peak message, 2048 words) | **88.6%** (2304 beats in 2599 cycles) |
| **peak payload rate, WRITE** | **0.788 words/clock** (roofline 0.889 = MTU/(MTU+2)) |
| **peak payload rate, ACCUM** (512 words) | **0.451 words/clock** |
| sustained payload rate over all launches | 0.414 words/clock |
| transmitter cycles waiting on credits / on the wire | 7728 / 0 |
| datapath cycles waiting on the memory port | 14219 |
| scalar baseline (cost model) | 704436 cycles |
| **aggregate speedup** | **10.30x** |
| **peak speedup** | **15.01x** |

Cost-model terms (cycles per modelled scalar operation): descriptor word load 4, descriptor validation 24, packet header build 12, packet post 30, flow-control test 6, payload word out 8, payload word in 8, accumulated word in 13, completion word store 4, completion bookkeeping 20 - evaluated over 8672 descriptor loads, 2283 packet builds, 28328 words out, 19888 plain words in, 8440 accumulated words in and 1075 completions.

The full-memory sweep compares all 70656 words of the simulated shared memory against the golden image after every pass, so a write anywhere outside a destination region, a completion slot, or past the end of a message fails the run. The memory model also counts out-of-range accesses: 0.

TEST PASSED
