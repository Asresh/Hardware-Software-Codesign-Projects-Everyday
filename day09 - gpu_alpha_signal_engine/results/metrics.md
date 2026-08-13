# Day 9 - Alpha-Signal Engine: measured results

All figures are extracted from the Icarus Verilog run (`results/sim.log`) and the golden generator (`tb/vectors/sw_metrics.txt`).

## Verification

| Quantity | Value |
|---|---|
| Streams | 264 |
| Ticks processed | 57,959 |
| Records checked (2 passes) | 115,918 |
| Field mismatches | 0 |
| Control-plane errors | 0 |

## Throughput & latency

| Metric | Value |
|---|---|
| Sustained ingest (full rate) | 1.000 ticks/clock |
| Signal latency (tick to record) | 84 cycles |
| HW cycles (all streams, incl. drain) | 80,135 |
| Ingest span (all streams) | 57,959 cycles |

## Speedup vs scalar baseline

| Metric | Value |
|---|---|
| Scalar baseline cycles | 4,385,705 |
| Scalar steady cost/tick | 83.0 cycles |
| **Aggregate speedup** | **54.73x** |
| **Peak speedup (steady state)** | **83.00x** |

