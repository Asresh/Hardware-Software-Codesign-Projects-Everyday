# Measured results

All hardware figures are read straight from the Icarus run (`results/sim.log`); the baseline is the documented scalar cost model in `sw/ann_baseline.c`.

| metric | value |
|---|---|
| searches / pass | 49 |
| database vectors / pass | 7364 |
| stream beats / pass | 58912 |
| dimensions scored / pass | 471296 |
| result entries checked | 762 |
| mismatches | 0 |
| full-rate cycles (aggregate) | 58961 |
| bubble-pass cycles (aggregate) | 84252 |
| sustained throughput | 7.993 dims/clock |
| sustained throughput | 0.1249 vectors/clock |
| peak throughput (search 0) | 8.000 dims/clock (roofline P=8) |
| peak-search latency (fill+drain) | 1 cycles |
| scalar baseline (cost model) | 1285216 cycles |
| **aggregate speedup** | **21.80x** |
| **peak speedup** | **25.00x** |
