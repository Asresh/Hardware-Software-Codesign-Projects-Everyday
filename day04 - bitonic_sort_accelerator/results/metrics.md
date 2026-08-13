# Measured results

Extracted from `results/sim.log` (Icarus Verilog) and the scalar baseline cost model. Numbers are measured, not asserted.

| Metric | Value |
|---|---|
| Jobs run | 286 |
| Output keys checked | 275984 |
| Mismatches vs golden | 0 |
| Keys per tile (N) | 16 |
| Tiles sorted | 17249 |
| Total hardware cycles | 20941 |
| Total keys sorted | 275984 |
| Sustained throughput | 13.18 keys/cycle |
| Peak job keys | 2048 |
| Peak job cycles | 141 |
| Peak throughput | 14.52 keys/cycle |
| Scalar baseline (model) | 128 cycles/tile |
| Aggregate baseline cycles | 2207872 |
| Aggregate speedup | 105.43x |
| Peak speedup | 116.20x |

Ideal steady-state throughput is 16 keys/cycle (one coalesced 16-key tile sorted per clock); the peak measured 14.52 keys/cycle is that bound minus the fixed pipeline fill/drain.
