# Measured results

Extracted from `results/sim.log` (Icarus Verilog) and the scalar baseline cost model. Hardware cycles are measured from RTL simulation; the software baseline is a dynamic instruction count over the real draw workload at one op per cycle.

| Metric | Value |
|---|---|
| Jobs run | 294 |
| Random words checked | 276808 |
| Mismatches vs golden | 0 |
| Philox draws generated | 69202 |
| Random 32-bit words generated | 276808 |
| Total hardware cycles | 20356 |
| Sustained throughput | 3.40 draws/cycle (13.60 words/cycle) |
| Peak job draws | 504 |
| Peak job cycles | 136 |
| Peak throughput | 3.71 draws/cycle (14.82 words/cycle) |
| Ideal throughput | 4.0 draws/cycle (16.0 words/cycle) |
| Scalar baseline (model) | 130 ops/draw |
| Aggregate baseline cycles | 8996260 |
| Aggregate speedup | 441.95x |
| Peak speedup | 481.76x |

Ideal steady-state throughput is 4.0 draws/cycle (16.0 random words/cycle): the 4-lane SIMD array retires one Philox-4x32-10 block per lane per clock. The peak measured 3.71 draws/cycle is that bound minus the fixed pipeline fill/drain (the lanes are ROUNDS stages deep) and per-job setup; the gap shrinks with longer jobs.
