# Hardware/Software Co-Design Projects — Everyday

A daily portfolio of complete, non-trivial hardware/software co-design projects. Each day is a self-contained accelerator: parameterized SystemVerilog RTL with a real hardware/software interface, working C or host software that configures and drives it, and a self-checking differential testbench that verifies the hardware bit-exactly against a software golden model.

Every project ships with:

- **Synthesizable, parameterized RTL** — at least three submodules plus a top level, elaborating cleanly at multiple parameter sets.
- **A real HW/SW interface** — AXI4-Lite/AXI4-Stream, memory-mapped registers, DMA, or similar — with a documented register map or protocol.
- **Software that does real work** — configures the device, moves data, handles completion, and computes the reference result.
- **Measured results** — cycle counts, throughput, latency, and a hardware-versus-software speedup, extracted from simulation rather than asserted.
- **Hand-drawn diagrams** — a hardware block diagram and a title banner, plus a Mermaid transaction sequence.

Verification runs under **Icarus Verilog** (this environment has no Verilator/Yosys); where a synthesized area report is unavailable, an analytical estimate is given instead. See each day's README for the exact toolchain and any substitutions.

## Index

| Day | Project | Domain | Microarchitecture | Interface | Summary |
|---|---|---|---|---|---|
| [11](day11%20-%20gpu_crc_feed_integrity_engine) | Feed-Integrity Engine (HFT CRC + sequence check) | error-correcting codes / market-data feed integrity (HFT) | combinational GF(2) CRC-32 fold (unrolled LFSR) + AXI4-Stream framing FSM + per-channel sequence RAM | AXI4-Stream packet ingress + AXI4-Lite control + integrity-failure IRQ | Line-rate feed-handler integrity check: a combinational CRC-32/FCS fold verifies **4 payload bytes/clock** while a framing FSM + per-channel sequence RAM catch bad CRCs and dropped-packet gaps, raising a sticky IRQ — **3.77 sustained / 3.99 peak bytes/clock**, **2-cycle** latency, **31.02× / 31.98× over scalar**; KAT-anchored (0xCBF43926), 315 packets / 27,838 bytes per pass under randomised bubbles + full rate, 37 CRC errors + 30 gaps caught, 632 records checked, 0 mismatches |
| [10](day10%20-%20gpu_bitpack_decode_engine) | Bit-Pack Decode Engine (HFT columnar decompression) | compression / columnar market-data decompression (HFT) | streaming bit-unpack dataflow: variable-rate bit-FIFO aligner + 4-lane barrel-shift field extractor + combinational zig-zag / 4-wide delta-prefix tail | AXI4-Stream compressed in + wide 128-bit AXI4-Stream decoded out + AXI4-Lite control + block-done/error IRQ | Line-rate columnar (FOR + delta + zig-zag + bit-pack) feed decompression: a 192-bit variable-rate bit-FIFO feeds a 4-lane barrel-shift extractor and a combinational zig-zag + 4-wide delta-prefix tail retiring up to **4 int32 values/clock** at **5-cycle** latency, **1.86 sustained / 4.00 peak values/clock**, **20.76× / 39.85× over scalar**; 268 blocks / 67,171 values / 138,438 checked decodes, 0 mismatches |
| [9](day9%20-%20gpu_alpha_signal_engine) | Alpha-Signal Engine (HFT streaming signals) | quantitative finance / real-time trading signals (HFT) | deeply-pipelined fixed-point datapath + single-cycle read-modify-write per-symbol state loop + unrolled integer sqrt/divider | AXI4-Stream ticks in + AXI4-Stream signals out + AXI4-Lite control + alert IRQ | Ultra-low-latency "alpha in the wire": per-symbol fast/slow EWMA + rolling variance in a single-cycle RMW symbol RAM feed a 32-stage integer sqrt then 48-stage divider to emit a z-score / momentum / alert record every tick at a sustained **1.000 ticks/clock**, **84-cycle** deterministic latency, **54.73× / 83.00× over scalar**; 264 streams / 57,959 ticks / 115,918 checked records, 0 mismatches |
| [8](day8%20-%20gpu_order_book_engine) | CAM Limit Order-Book / BBO Engine | networking / market-data (HFT) | content-addressable price-level map (associative memory) + log-depth BBO comparator trees | AXI4-Stream ingress + MMIO control/snapshot + BBO-update IRQ | Ultra-low-latency HFT book build: single-cycle parallel `(side,price)` match/update over 32 CAM levels, two comparator trees pick best-bid/best-ask, top of book republished 2 cycles after every message at ~1 msg/clock, **39.61× / 200.00× over scalar**; 266 streams / 8,214 messages / 16,428 checked BBO records, 0 mismatches |
| [7](day7%20-%20gpu_cordic_sfu_engine) | CORDIC Special Function Unit (SFU) | physics kernels / transcendental math | iterative CORDIC engine (unified circular/hyperbolic) + SIMD lanes | shared submission/completion ring buffer + gather/scatter masters + IRQ | GPU SFU pool: sin/cos/exp/cosh/sinh/atan2/hypot/ln/sqrt on one shift-and-add CORDIC datapath, 4-lane SIMD, ~9 cycles/function, **34.47× / 35.58× over scalar**; 264 jobs / 39,759 checked words, 0 mismatches, 1.15e-7 max error vs libm (~23 bits) |
| [6](day6%20-%20gpu_philox_rng_engine) | Philox Counter-Based RNG Engine | cryptography / Monte-Carlo RNG | fully-pipelined counter-based (Philox-4x32-10) datapath + SIMD lanes | MMIO mailbox + doorbell + IRQ, coalesced wide masked write master | GPU/cuRAND RNG core, 4-lane SIMD retires one 128-bit block/lane/clock (512 random bits/clock), 3.40 sustained / 3.71 peak draws/cycle (4.0 ideal), **441.95× / 481.76× over scalar**; 294 jobs / 276,808 checked words, 0 mismatches |
| [5](day5%20-%20gpu_texture_filter_engine) | Bilinear Texture-Filter Engine | image / video processing | line-buffer window + 2×2 texel gather + Q16.16 bilinear blend | mailbox + doorbell + IRQ, coalesced wide memory master | GPU texture unit, two-row line buffer retires one filtered pixel/clock, 0.67 sustained / 0.97 peak pixels/cycle (1.0 ideal), **22.49× / 32.35× over scalar**; 290 jobs / 314,316 pixels, 0 mismatches |
| [4](day4%20-%20bitonic_sort_accelerator) | Tiled Bitonic Sort Accelerator | search acceleration / sorting | pipelined Batcher bitonic sorting network (compare-exchange lane array) | MMIO + coalesced wide-DMA master + IRQ | GPU block-sort primitive, 10-stage / 80-cell network retires one 16-key (512-bit) tile/clock, 13.18 sustained keys/cycle (16.0 ideal), **105.43× / 116.20× over scalar**; 286 jobs / 275,984 checked keys, 0 mismatches |
| [3](day3%20-%20scan_prefix_sum_engine) | Parallel Prefix-Sum (Scan) Engine | graph analytics / parallel primitives | parallel-prefix (Kogge-Stone) tree w/ carry chaining | APB + descriptor-driven wide DMA | GPU scan primitive, 16-lane prefix tree, 15.06 sustained words/cycle (16.0 ideal), **45.18× over scalar**; 292 jobs / 257,960 checked outputs, 0 mismatches |
| [2](day2%20-%20systolic_gemm_accelerator) | Systolic GEMM Accelerator | ML inference | output-stationary systolic array | Wishbone B4 | 8×8 INT8 MAC array with K-accumulate tiling, up to 64 MAC/cycle, **49.35× over scalar**; 273 jobs / 17,152 checked outputs, 0 mismatches |
| [1](day1%20-%20fir_stream_accelerator) | Streaming FIR Accelerator | DSP | streaming dataflow w/ FIFO backpressure | AXI4-Lite + AXI4-Stream | Transposed-form FIR, 8 MAC/cycle, ~1 sample/clock, **7.88× over scalar**; 1354-sample differential test, 0 mismatches |

## Layout

```
dayN - <project_name>/
├── README.md          project write-up (problem, partition, architecture, results)
├── Makefile           make sw | sim | metrics | elab | synth | formal | all
├── docs/              banner.svg, block_diagram.svg, waveform.svg
├── rtl/               synthesizable sources
├── tb/                testbench + golden vectors
├── sw/                firmware / driver / host application + reference
├── scripts/           build, metric extraction, diagram generation
└── results/           metrics.md (committed) + sim.log/vcd (generated)
```

## License

MIT — see [LICENSE](LICENSE).
