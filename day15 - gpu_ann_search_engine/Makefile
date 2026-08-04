# =============================================================================
# Day 15 - GPU vector-search (ANN) top-K engine
#   make sw      build host/driver/reference/baseline and generate vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make elab    elaborate the RTL at three distinct parameter sets
#   make synth   report flop/LUT area (analytical; Yosys not present here)
#   make all     sw -> sim -> metrics
#   make clean   remove build artifacts
# =============================================================================

# ---- design parameters ----
D ?= 64
P ?= 8
K ?= 8

# ---- stimulus controls ----
NRAND ?= 40
NMAX  ?= 256
PEAK  ?= 2048
SEED  ?= 0x0D15A11C0DE0D15

# ---- tools ----
CC       ?= cc
CFLAGS   ?= -std=c11 -O2 -Wall -Wextra
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

RTL   := $(wildcard rtl/*.v)
TB    := tb/ann_tb.sv
VEC   := tb/vectors
CONST := $(VEC)/ann_const.vh
STREAM:= $(VEC)/stream.hex
HOST  := sw/ann_host
SIM   := results/ann_sim.vvp

.PHONY: all sim sw vectors metrics elab synth clean

all: sim metrics

# ---------------- software: host / driver / reference / baseline ------------
$(HOST): sw/ann_host.c sw/ann_ref.c sw/ann_baseline.c sw/ann_driver.c sw/ann.h
	$(CC) $(CFLAGS) -DANN_D=$(D) -DANN_P=$(P) -DANN_K=$(K) -c -o /dev/null sw/ann_driver.c   # firmware build check
	$(CC) $(CFLAGS) -DANN_D=$(D) -DANN_P=$(P) -DANN_K=$(K) -o $@ sw/ann_host.c sw/ann_ref.c sw/ann_baseline.c

sw: $(HOST)

# ---------------- test vectors + golden + params ----------------------------
$(STREAM): $(HOST)
	@mkdir -p $(VEC)
	./$(HOST) --nrand $(NRAND) --nmax $(NMAX) --peak $(PEAK) --seed $(SEED) --outdir $(VEC)

$(CONST): $(STREAM)

vectors: $(STREAM)

# ---------------- simulation ------------------------------------------------
$(SIM): $(RTL) $(TB) $(CONST)
	@mkdir -p results
	$(IVERILOG) -g2012 -o $@ -s ann_tb -Irtl -I$(VEC) $(RTL) $(TB)

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
	   yosys -q -p "read_verilog -I rtl $(RTL); hierarchy -top ann_search_top; synth -top ann_search_top; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --d $(D) --p $(P) --k $(K) ; \
	 fi

clean:
	rm -f $(HOST) $(SIM) results/elab_*.vvp
	rm -f $(VEC)/stream.hex $(VEC)/searches.txt $(VEC)/ann_const.vh $(VEC)/sw_metrics.txt
	rm -f results/*.vcd results/sim.log results/metrics.md
