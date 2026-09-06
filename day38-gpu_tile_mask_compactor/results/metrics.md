<!-- Author: Asresh -->
# Measured results

Toolchain: Icarus Verilog 13.0 and Apple Clang C11 on September 6, 2026.

| Metric | Measured value |
|---|---:|
| Tile masks | 320 |
| Directed / randomized | 8 / 312 |
| End-to-end clocks | 783 |
| Masks per clock | 0.408685 |
| Mean clocks per mask | 2.446875 |
| Unstalled pipeline latency | 1 clock |
| Checks / mismatches | 645 / 0 |
| C reference checksum | `0x10611f3840e9a09e` |

The clock count includes two AHB-Lite configuration writes, deterministic source gaps, randomized output backpressure, four counter reads, and interrupt acknowledgement. C warnings-as-errors and ASan/UBSan passed. Yosys was unavailable; synthesis-oriented Icarus elaboration passed, so no area, frequency, power, or speedup measurement is reported.
