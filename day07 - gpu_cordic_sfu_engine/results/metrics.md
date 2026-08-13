# Measured results

Extracted from `results/sim.log` (Icarus Verilog) and the scalar baseline cost model. Hardware cycles are measured from RTL simulation; the software baseline is a dynamic instruction count over the real request workload at one op per cycle. Accuracy is the worst-case error of the fixed-point CORDIC against IEEE double libm, checked over every generated result.

| Metric | Value |
|---|---|
| Jobs run | 264 |
| Result words checked | 39759 |
| Mismatches vs golden | 0 |
| Function requests evaluated | 13253 |
| Total hardware cycles | 119437 |
| Sustained throughput | 0.111 functions/cycle (9.01 cycles/function) |
| Peak job requests | 56 |
| Peak job cycles | 489 |
| Peak throughput | 0.115 functions/cycle (8.73 cycles/function) |
| SIMD lanes | 4 |
| CORDIC latency | 28 (circular) / 29 (hyperbolic) core cycles |
| Scalar baseline cycles | 4117512 |
| Aggregate speedup | 34.47x |
| Peak speedup | 35.58x |
| Max abs error vs libm | 1.15e-07 |

Each function is one iterative CORDIC pass: 28 shift-and-add micro-rotations (circular: sin/cos, atan2/hypot) or 29 (hyperbolic: exp, cosh/sinh, ln, sqrt). The 4-lane SIMD array evaluates 4 functions per wave, so the per-function cost amortises to 9.01 cycles including ring read/write and pipeline fill/drain. The fixed-point unit tracks IEEE double libm to 1.15e-07 worst-case absolute error (~23 bits) across all six functions.
