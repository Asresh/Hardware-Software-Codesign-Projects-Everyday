# Measured results

Extracted from `results/sim.log` (Icarus Verilog) and the scalar baseline cost model. Numbers are measured, not asserted.

| Metric | Value |
|---|---|
| Jobs run | 292 |
| Output words checked | 257960 |
| Mismatches vs golden | 0 |
| Lanes (words/beat) | 16 |
| Total hardware cycles | 17127 |
| Total elements scanned | 257960 |
| Sustained throughput | 15.06 words/cycle |
| Peak job length | 2047 elements |
| Peak job cycles | 131 |
| Peak throughput | 15.63 words/cycle |
| Scalar baseline (model) | 3 cycles/element |
| Aggregate baseline cycles | 773880 |
| Aggregate speedup | 45.18x |
| Peak speedup | 46.88x |

Ideal steady-state throughput is 16 words/cycle (one coalesced 16-word beat per clock); the peak measured 15.63 words/cycle is that bound minus the fixed pipeline fill/drain.
