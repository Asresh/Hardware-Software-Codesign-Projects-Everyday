# Day 14 - GPU All-Reduce Collective Engine - measured results

| metric | value |
|---|---|
| collectives (descriptors) / pass | 49 |
| elements reduced / groups | 3627 / 924 |
| gather->scatter latency | 4 cycles |
| sustained throughput | 2.8695 words/clock |
| peak throughput (single big collective) | 3.9690 words/clock |
| span, full ring | 1264 cycles (3627 words) |
| span, peak collective | 516 cycles (2048 words) |
| scalar baseline | 65286 cycles (18/element) |
| **aggregate speedup** | **51.65x** |
| **peak speedup** | **71.44x** |
| Pass A (memory wait states) | 0 mismatches |
| Pass B (full rate) | 0 mismatches |
| Peak (descriptor 0 alone) | 0 mismatches |
| CSR statistics check | OK |
| error / IRQ check | OK |
| overall | PASSED |

