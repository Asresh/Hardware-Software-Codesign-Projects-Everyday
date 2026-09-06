<!-- Author: Asresh -->
# Measured results

Toolchain: Icarus Verilog 13.0 and Apple Clang C11 on September 6, 2026.

| Metric | Measured value |
|---|---:|
| Transactions | 320 |
| Directed / randomized | 8 / 312 |
| End-to-end clocks | 1,399 |
| Transactions per clock | 0.228735 |
| Mean clocks per transaction | 4.371875 |
| Directory hits / misses | 19 / 301 |
| Routed node probes | 90 |
| Intentionally detected protocol errors | 126 |
| Checks / mismatches | 1,607 / 0 |
| C reference checksum | `0x7f17c1b908c940e2` |

The clock count includes deterministic request gaps, response backpressure, APB configuration, counter reads, and interrupt acknowledgement. C warnings-as-errors and ASan/UBSan passed. Yosys was unavailable; synthesis-oriented Icarus elaboration passed, so no area, frequency, power, or speedup measurement is reported.
