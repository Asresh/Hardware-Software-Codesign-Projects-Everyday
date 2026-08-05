# Measured results

All hardware figures are read straight from the Icarus run (`results/sim.log`); the baseline is the documented scalar cost model in `sw/emb_baseline.c`.

| metric | value |
|---|---|
| geometry (EMB_DIM / LANES / CHUNKS / MAX_BAG) | 64 / 4 / 16 / 64 |
| descriptors (bags) / pass | 319 (19 directed + 300 randomised) |
| indices examined / pass | 9523 |
| rows gathered from the local shard | 6000 (63.0%) |
| indices owned by a peer shard | 3521 (37.0%) |
| indices past the end of the global table | 2 |
| bags rejected for exceeding MAX_BAG | 1 |
| embedding words gathered + pooled / pass | 384000 |
| AXI4 read beats / write beats | 99134 / 5088 |
| pooled output words written / pass | 20416 |
| checks | 248960 |
| mismatches | 0 |
| full-rate cycles (aggregate) | 131651 |
| wait-state pass cycles (aggregate) | 356748 (225097 bus stall cycles) |
| single-buffer cycles (same results, overlap off) | 219490 |
| AXI4 bus occupancy (full rate) | 79.2% |
| sustained throughput | 2.9168 pooled words/clock (roofline 4) |
| peak throughput (peak descriptor, 64 local rows) | 3.3740 pooled words/clock (87.1% bus occupancy) |
| peak cycles / row (16-beat burst) | 18.97 |
| **double-buffering speedup** | **1.667x** |
| scalar baseline (cost model) | 1733292 cycles |
| **aggregate speedup** | **13.17x** |
| **peak speedup** | **14.08x** |

Cost-model terms (cycles per modelled scalar operation, one op per cycle): descriptor decode 6, index classify 6, row address 4, first-row element 3, folded element 4, mean element 22 (32-bit divide), copy-out element 2, empty-bag element 2 - evaluated over 420194 modelled operations.

TEST PASSED
