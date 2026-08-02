# Day 13 - GPU MoE Router Engine - measured results

| metric | value |
|---|---|
| tokens routed (main stream) | 316 |
| accepted / dropped slots | 507 / 125 |
| ingest->dispatch latency | 38 cycles |
| sustained throughput | 0.8927 tokens/clock |
| peak throughput (full-rate burst) | 1.0000 tokens/clock |
| span, main stream | 354 cycles |
| span, peak burst | 316 cycles (316 tokens) |
| scalar baseline | 41396 cycles (131.0/token) |
| **aggregate speedup** | **116.94x** |
| **peak speedup** | **131.00x** |
| max gate-weight error vs double softmax | 1.35e-04 |
| Pass A (bubbles+backpressure) | 0 mismatches |
| Pass B (full rate) | 0 mismatches |
| CSR statistics check | OK |
| capacity IRQ check | OK |
| overall | PASSED |

