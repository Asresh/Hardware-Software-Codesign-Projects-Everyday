# Day 8 - CAM Order-Book / BBO Engine - measured results

| Metric | Value |
|---|---|
| Streams (corner + random) | 266 (10 + 256) |
| Messages processed | 8214 |
| BBO records checked (2 passes) | 16428 |
| Mismatches vs golden model | 0 |
| Overflow streams (HW / SW) | 1 / 1 |
| Longest stream | 64 messages |
| CAM depth | 32 price levels |
| Message->BBO latency | 2 cycles |
| Sustained throughput | 0.939 messages/clock |
| HW cycles (full-rate pass) | 8746 |
| Baseline cycles (scalar model) | 346464 |
| Baseline cost / message (avg) | 42.18 cycles |
| Baseline peak / message | 200 cycles |
| **Aggregate speedup** | **39.61x** |
| **Peak speedup** (full book) | **200.00x** |
| Status | **PASS** |

Throughput = messages / full-rate HW cycles (includes the 2-cycle pipeline drain per stream). Aggregate speedup = total scalar-model cycles / full-rate HW cycles over the identical message corpus. Peak speedup = worst-case scalar per-message cost (full 32-level book) against the engine's steady-state 1 message/clock.
