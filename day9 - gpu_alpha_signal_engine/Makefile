# =============================================================================
# Day 9 - GPU/FPGA alpha-signal engine
#   make sw      build the host / driver / reference / baseline, gen vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make elab    elaborate the RTL at three distinct parameter sets
#   make synth   report flop/adder area (analytical; Yosys not present here)
#   make all     sw -> sim -> metrics
#   make clean   remove build artifacts
# =============================================================================

# ---- design parameters (single source of truth for RTL, SW and vectors) ----
N_SYM   ?= 64
SYMW    ?= 6
FRAC    ?= 16

# ---- stimulus controls ----
NRAND   ?= 256
SEED    ?= 0x5EED0009

# ---- tools ----
CC       ?= cc
CFLAGS   ?= -std=c11 -O2 -Wall -Wextra \
            -DN_SYM=$(N_SYM) -DSYMW=$(SYMW) -DFRAC=$(FRAC)
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

RTL   := $(wildcard rtl/*.v)
TB    := tb/as_tb.sv
VEC   := tb/vectors
CONST := $(VEC)/asig_const.vh
TICKS := $(VEC)/ticks.hex
HOST  := sw/asig_host
SIM   := results/as_sim.vvp

.PHONY: all sim sw vectors metrics elab synth clean

all: sim metrics

# ---------------- software: host / driver / reference / baseline ----------------
$(HOST): sw/asig_host.c sw/asig_ref.c sw/asig_baseline.c sw/asig_driver.c sw/asig.h
	$(CC) $(CFLAGS) -c -o /dev/null sw/asig_driver.c        # firmware build check
	$(CC) $(CFLAGS) -o $@ sw/asig_host.c sw/asig_ref.c sw/asig_baseline.c -lm

sw: $(HOST)

# ---------------- test vectors + golden + params ----------------
$(TICKS): $(HOST)
	@mkdir -p $(VEC)
	./$(HOST) --nrand $(NRAND) --seed $(SEED) --outdir $(VEC)

$(CONST): $(TICKS)

vectors: $(TICKS)

# ---------------- simulation ----------------
$(SIM): $(RTL) $(TB) $(CONST)
	@mkdir -p results
	$(IVERILOG) -g2012 -o $@ -s as_tb -I$(VEC) $(RTL) $(TB)

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
# analytical flop/adder estimate from the parameters instead (see README).
synth:
	@if command -v yosys >/dev/null 2>&1; then \
	   yosys -q -p "read_verilog $(RTL); hierarchy -top alpha_signal_engine; synth -top alpha_signal_engine; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --nsym $(N_SYM) --frac $(FRAC) ; \
	 fi

clean:
	rm -f $(HOST) $(SIM)
	rm -f $(VEC)/*.hex $(VEC)/asig_const.vh $(VEC)/sw_metrics.txt
	rm -f results/*.vcd results/sim.log results/metrics.md
