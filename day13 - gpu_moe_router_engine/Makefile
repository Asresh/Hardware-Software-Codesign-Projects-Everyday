# =============================================================================
# Day 13 - GPU Mixture-of-Experts top-k routing / gating engine
#   make sw      build host/driver/reference/baseline and generate vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make elab    elaborate the RTL at three distinct parameter sets
#   make synth   report flop/LUT area (analytical; Yosys not present here)
#   make all     sw -> sim -> metrics
#   make clean   remove build artifacts
# =============================================================================

# ---- design parameters ----
E   ?= 8
K   ?= 2

# ---- stimulus controls ----
NRAND ?= 300
SEED  ?= 0x0D13C0DEC0DE0D13
CAP   ?= 64

# ---- tools ----
CC       ?= cc
CFLAGS   ?= -std=c11 -O2 -Wall -Wextra
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

RTL   := $(wildcard rtl/*.v)
TB    := tb/moe_tb.sv
VEC   := tb/vectors
CONST := $(VEC)/moe_const.vh
TOK   := $(VEC)/tokens.hex
HOST  := sw/moe_host
SIM   := results/moe_sim.vvp

.PHONY: all sim sw vectors metrics elab synth clean

all: sim metrics

# ---------------- software: host / driver / reference / baseline ------------
$(HOST): sw/moe_host.c sw/moe_ref.c sw/moe_baseline.c sw/moe_driver.c sw/moe.h
	$(CC) $(CFLAGS) -DMOE_E=$(E) -DMOE_K=$(K) -c -o /dev/null sw/moe_driver.c   # firmware build check
	$(CC) $(CFLAGS) -DMOE_E=$(E) -DMOE_K=$(K) -o $@ sw/moe_host.c sw/moe_ref.c sw/moe_baseline.c -lm

sw: $(HOST)

# ---------------- test vectors + golden + params ----------------------------
$(TOK): $(HOST)
	@mkdir -p $(VEC)
	./$(HOST) --nrand $(NRAND) --seed $(SEED) --cap $(CAP) --outdir $(VEC)

$(CONST): $(TOK)

vectors: $(TOK)

# ---------------- simulation ------------------------------------------------
$(SIM): $(RTL) $(TB) $(CONST)
	@mkdir -p results
	$(IVERILOG) -g2012 -o $@ -s moe_tb -I$(VEC) \
	    -Pmoe_router_engine.E=$(E) -Pmoe_router_engine.K=$(K) \
	    $(RTL) $(TB)

sim: vectors $(SIM)
	@mkdir -p results
	cd $(VEC) && $(VVP) ../../$(SIM) | tee ../../results/sim.log
	@if grep -q "TEST FAILED" results/sim.log; then echo "SIMULATION FAILED"; exit 1; fi
	@if ! grep -q "TEST PASSED" results/sim.log; then echo "NO PASS MARKER"; exit 1; fi

# ---------------- metrics ---------------------------------------------------
metrics:
	$(PYTHON) scripts/extract_metrics.py results/sim.log $(VEC)/sw_metrics.txt > results/metrics.md
	@echo "wrote results/metrics.md"

# ---------------- elaboration at three parameter sets -----------------------
elab:
	@bash scripts/elaborate.sh

# ---------------- synthesis / area ------------------------------------------
synth:
	@if command -v yosys >/dev/null 2>&1; then \
	   yosys -q -p "read_verilog $(RTL); hierarchy -top moe_router_engine; synth -top moe_router_engine; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --e $(E) --k $(K) ; \
	 fi

clean:
	rm -f $(HOST) $(SIM) results/elab_*.vvp
	rm -f $(VEC)/*.hex $(VEC)/moe_const.vh $(VEC)/sw_metrics.txt $(VEC)/golden.txt
	rm -f results/*.vcd results/sim.log results/metrics.md
