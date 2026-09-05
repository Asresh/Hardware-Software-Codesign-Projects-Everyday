<!-- Author: Asresh -->
# Measured results

Toolchain: Icarus Verilog 13.0 and Apple Clang C11 on 2026-09-05.

| Metric | Reproduced value |
|---|---:|
| Frames | 260 (4 directed + 256 randomized) |
| Samples | 16,640 |
| End-to-end clocks | 48,376 |
| Samples/clock | 0.343972 |
| Mean clocks/frame | 186.062 |
| Testbench checks | 1,570 |
| Mismatches | 0 |
| C reference checksum | `0x00000000003fc805` |

The clock count includes randomized source gaps and Wishbone result reads/interrupt acknowledgement after every frame. C warnings-as-errors and ASan/UBSan checks passed. Yosys was unavailable; synthesis-oriented Icarus elaboration and an alternate 16-bit-sample/48-bit-accumulator elaboration passed. No synthesis area, timing, power, or speedup measurement is claimed.
