# Measured results

All hardware figures are read straight from the Icarus run (`results/sim.log`); the baseline is the documented scalar cost model in `sw/kvp_baseline.c`.

| metric | value |
|---|---|
| batches / pass | 16 |
| request words / pass | 371 |
| translations / pass | 1909 |
| served from the translation cache | 610 (32.0%) |
| block-table walks | 1299 |
| physical blocks allocated / returned | 539 / 162 |
| result words written / pass | 1955 |
| checks | 8464 |
| mismatches | 0 |
| full-rate cycles (aggregate) | 4971 |
| wait-state pass cycles (aggregate) | 11854 (6883 memory stall cycles) |
| Wishbone transactions (full rate) | 4647 (93.5% bus occupancy) |
| sustained throughput | 0.3840 translations/clock |
| sustained throughput | 0.3933 result words/clock |
| peak throughput (batch 10, fully cached) | 0.9697 translations/clock (512 in 528 cycles) |
| single-translation latency (start -> done) | 3 cycles |
| scalar baseline (cost model) | 64716 cycles |
| **aggregate speedup** | **13.02x** |
| **peak speedup** | **20.42x** |

Cost-model terms (cycles per modelled operation, one op per cycle): request decode 4, cached translation 21, block-table walk 34, walk + allocate 42, block release 12.
