# Day 11 - Feed-Integrity Engine - measured results

All numbers are from the Icarus simulation of the RTL against the C golden model.

| Metric | Value |
|---|---|
| Packets processed (per pass) | 315 |
| Ingress beats (per pass) | 7383 |
| Bytes CRC-checked (per pass) | 27838 |
| Payload length range | 0..591 bytes |
| Engine active cycles (full rate) | 7383 |
| Wall cycles first-in..last-out (full rate) | 7383 |
| Sustained throughput (aggregate) | 3.770 bytes/clock |
| **Peak throughput** (2 KB packet) | **3.992 bytes/clock** |
| Result latency (trailer in -> result out) | 2 cycles |
| Scalar baseline (documented cost model) | 229004 cycles |
| **Speedup (aggregate)** | **31.02x** |
| **Speedup (peak)** | **31.98x** |
| CRC errors detected | 37 (injected 37) |
| Sequence gaps detected | 30 (injected 30) |
| Records checked (2 passes + peak + malformed) | 632 |
| Mismatches vs golden | 0 |

Result: **PASS** (KAT CRC32("123456789")=0xCBF43926, 2 passes: randomised ingress bubbles + full rate, a 2 KB peak micro-benchmark, and a malformed-frame error/IRQ test).
