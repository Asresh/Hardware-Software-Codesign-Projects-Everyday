# Day 10 - Bit-Pack Decode Engine - measured results

All numbers are from the Icarus simulation of the RTL against the C golden model.

| Metric | Value |
|---|---|
| Blocks decoded | 268 |
| Values decoded (per pass) | 67171 |
| Compressed ingress words | 33632 |
| Width range across blocks | 0..32 bits |
| Engine active cycles (full rate) | 35884 |
| Wall cycles first-in..last-out (full rate) | 36147 |
| Sustained throughput (aggregate) | 1.8583 values/clock |
| **Peak throughput** (width 8) | **4.0000 values/clock** |
| Decode latency (first word in -> first value out) | 5 cycles |
| Scalar baseline (documented cost model) | 744899 cycles |
| **Speedup (aggregate)** | **20.76x** |
| **Speedup (peak)** | **39.85x** |
| Mismatches vs golden | 0 |

Result: **PASS** (2 passes: randomised backpressure + full rate, plus a peak micro-benchmark and a malformed-block error test).
