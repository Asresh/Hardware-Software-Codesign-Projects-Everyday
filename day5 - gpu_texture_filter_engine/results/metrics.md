# Measured results

Extracted from `results/sim.log` (Icarus Verilog) and the scalar baseline cost model. Hardware cycles are measured from RTL simulation; the software baseline is a dynamic instruction count over the real pixel workload at one op per cycle.

| Metric | Value |
|---|---|
| Jobs run | 290 |
| Output words checked | 78579 |
| Mismatches vs golden | 0 |
| Output pixels filtered | 314316 |
| Total hardware cycles | 467128 |
| Sustained throughput | 0.67 pixels/cycle |
| Peak job pixels | 3392 |
| Peak job cycles | 3504 |
| Peak throughput | 0.97 pixels/cycle |
| Scalar baseline (model) | 33 ops/pixel core, 33.4 effective |
| Aggregate baseline cycles | 10505316 |
| Aggregate speedup | 22.49x |
| Peak speedup | 32.35x |

Ideal steady-state throughput is 1.0 pixel/cycle (the blend datapath retires one filtered pixel per clock); the peak measured 0.97 pixels/cycle is that bound minus line-buffer load and the fixed per-row/per-job setup.
