# Day 21 - measured results

Geometry: instruction memory 2^12 words, data memory 2^12 words, MX block 32 elements.

## Verification

| quantity | value |
|---|---|
| jobs run (two passes plus recovery) | 1561 |
| checks | 1357215 |
| mismatches | 0 |
| instruction commits compared against the simulator | 243523 |
| data-memory words compared | 110303 |
| full-memory sweep words | 8192 |
| output words compared against the C model by the host | 15090 |

## Cast throughput, measured on the core

Both versions of each kernel ran over the same 94 blocks (3008 elements).

| kernel | cycles/block | instructions/block | cycles/element |
|---|---|---|---|
| quantise, custom-0 | 194.4 | 174.8 | 6.08 |
| quantise, base RV32I | 2324.5 | 1959.0 | 72.64 |
| dequantise, custom-0 | 91.4 | 86.8 | 2.86 |
| dequantise, base RV32I | 685.2 | 598.6 | 21.41 |

## Speedup

| kernel | cycles | instructions |
|---|---|---|
| quantise | 11.96x | 11.21x |
| dequantise | 7.50x | 6.90x |
| round trip | 10.53x | 9.78x |

## Whole experiment

| kernel | jobs | blocks | elements | cycles | instructions | custom-0 ops |
|---|---|---|---|---|---|---|
| quant custom | 328 | 623 | 19936 | 120437 | 108272 | 30527 |
| quant base | 58 | 94 | 3008 | 218507 | 184143 | 0 |
| dequant custom | 328 | 623 | 19936 | 56268 | 53448 | 9968 |
| dequant base | 58 | 94 | 3008 | 64408 | 56264 | 0 |

## Pipeline

| quantity | value |
|---|---|
| instructions per cycle, quantise with custom-0 | 0.899 |
| instructions per cycle, dequantise with custom-0 | 0.950 |
| custom-0 instructions per element, quantise | 1.531 |
| custom-0 instructions per element, dequantise | 0.500 |
| cycles = instret + taken branches + 2 | held on every job |

## Code size

| kernel | instruction words |
|---|---|
| quant custom | 50 |
| quant base | 169 |
| dequant custom | 40 |
| dequant base | 92 |
| isa | 133 |

