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
