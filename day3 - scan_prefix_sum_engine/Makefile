# =============================================================================
# Day 3 - Parallel Prefix-Sum (Scan) Engine
#   make sw      build host / driver / reference / baseline and generate vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make elab    elaborate the RTL at three distinct parameter sets
#   make synth   report cell/FF area (analytical; Yosys not present here)
#   make all     sw -> sim -> metrics
#   make clean   remove build artifacts
# =============================================================================

# ---- design parameters (single source of truth for RTL, SW and vectors) ----
LANES      ?= 16
W          ?= 32
ADDR_WIDTH ?= 20
LEN_WIDTH  ?= 20

# ---- stimulus controls ----
NRAND      ?= 256
SEED       ?= 0xC0FFEE
MAX_LEN    ?= 2048

# ---- tools ----
CC        ?= cc
CFLAGS    ?= -std=c11 -O2 -Wall -Wextra
IVERILOG  ?= iverilog
VVP       ?= vvp
PYTHON    ?= python3

RTL      := $(wildcard rtl/*.v)
TB       := tb/scan_tb.sv
VEC      := tb/vectors
PARAMS   := $(VEC)/params.vh
JOBS     := $(VEC)/jobs.txt
HOST     := sw/scan_host
SIM      := results/scan_sim.vvp

.PHONY: all sim sw vectors metrics elab synth clean

all: sim metrics

# ---------------- software: host / driver / reference / baseline ----------------
$(HOST): sw/scan_host.c sw/scan_ref.c sw/scan_baseline.c sw/scan_accel.h
	$(CC) $(CFLAGS) -o $@ sw/scan_host.c sw/scan_ref.c sw/scan_baseline.c

sw: $(HOST)

# ---------------- test vectors + golden + params ----------------
$(JOBS): $(HOST)
	@mkdir -p $(VEC)
	./$(HOST) --lanes $(LANES) --width $(W) --addr-width $(ADDR_WIDTH) \
	          --len-width $(LEN_WIDTH) --nrand $(NRAND) --seed $(SEED) \
	          --max-len $(MAX_LEN) --outdir $(VEC)

$(PARAMS): $(JOBS)

vectors: $(JOBS)

# ---------------- simulation ----------------
$(SIM): $(RTL) $(TB) $(PARAMS)
	@mkdir -p results
	$(IVERILOG) -g2012 -Wall -o $@ -s scan_tb -I$(VEC) $(RTL) $(TB)

sim: vectors $(SIM)
	@mkdir -p results
	$(VVP) $(SIM) | tee results/sim.log
	@if grep -q "TEST FAILED" results/sim.log; then echo "SIMULATION FAILED"; exit 1; fi
	@if ! grep -q "TEST PASSED" results/sim.log; then echo "NO PASS MARKER"; exit 1; fi

# ---------------- metrics ----------------
metrics:
	$(PYTHON) scripts/extract_metrics.py results/sim.log $(VEC)/sw_metrics.txt > results/metrics.md
	@echo "wrote results/metrics.md"

# ---------------- elaboration at three parameter sets ----------------
elab:
	@bash scripts/elaborate.sh

# ---------------- synthesis / area ----------------
# Yosys is not installed in this environment; scripts/area_estimate.py prints an
# analytical gate/FF estimate from the parameters instead (see README section 9).
synth:
	@if command -v yosys >/dev/null 2>&1; then \
	   yosys -q -p "read_verilog $(RTL); hierarchy -top scan_top; synth -top scan_top; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --lanes $(LANES) --width $(W) \
	       --addr-width $(ADDR_WIDTH) --len-width $(LEN_WIDTH) ; \
	 fi

clean:
	rm -f $(HOST) $(SIM)
	rm -f $(VEC)/*.hex $(VEC)/jobs.txt $(VEC)/sw_metrics.txt $(PARAMS)
	rm -f results/*.vcd results/sim.log results/metrics.md
