<!-- Author: Asresh -->
# Measured results

Measured with the deterministic Day 39 testbench:

- 320 request/completion vectors: 8 directed and 312 randomized.
- 760 end-to-end clocks under randomized request, issue, completion-order, and output stalls.
- 0.421053 ordered requests/clock; 2.375000 mean clocks/request.
- 143 completions arrived out of order and were retired correctly.
- Eight-request maximum occupancy reached; two deliberate invalid completions were contained and counted.
- 1,289 checks, zero mismatches.
- C reference checksum: `0xe3aa05c61e46be77`.
- C warnings-as-errors, ASan, UBSan, RTL simulation, and synthesis-oriented Icarus elaboration passed.
- Yosys was unavailable, so no area, Fmax, power, or timing result is reported.
