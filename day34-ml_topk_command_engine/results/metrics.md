<!-- Author: Asresh -->
# Measured simulation results

| Metric | Measured value |
|---|---:|
| Input vectors | 320 |
| Differential mismatches | 0 |
| START-to-IRQ cycles | 3,464 |
| Sustained throughput | 0.092379 vectors/clock |
| Final accepted read to first result-valid | 4 clocks |
| Scalar embedded-CPU baseline | 51,595 cycles |
| End-to-end speedup | 14.894630x |

Measured by `make sim` with deterministic randomized DMA read/write stalls.
