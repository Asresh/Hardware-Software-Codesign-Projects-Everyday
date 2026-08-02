# Day 12 - Pre-Trade Risk Engine - measured results

| metric | value |
|---|---|
| orders checked (main stream) | 312 |
| accepted / rejected | 102 / 210 |
| ingest->decision latency | 2 cycles |
| sustained throughput | 0.9936 orders/clock |
| peak throughput (1024-order burst) | 0.9981 orders/clock |
| span, main stream | 314 cycles |
| span, peak burst | 1026 cycles (1024 orders) |
| scalar baseline | 16764 cycles (53.73/order) |
| **aggregate speedup** | **53.39x** |
| **peak speedup** | **53.63x** |
| Pass A (bubbles+backpressure) | 0 mismatches |
| Pass B (full rate) | 0 mismatches |
| CSR histogram check | OK |
| kill-switch / IRQ check | OK |
| overall | PASSED |

