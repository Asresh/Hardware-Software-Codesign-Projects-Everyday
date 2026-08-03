# =============================================================================
# Day 14 - GPU multi-GPU all-reduce collective engine
#   make sw      build host/driver/reference/baseline and generate vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make elab    elaborate the RTL at three distinct parameter sets
#   make synth   report flop/LUT area (analytical; Yosys not present here)
#   make all     sw -> sim -> metrics
#   make clean   remove build artifacts
# =============================================================================

# ---- design parameters ----
R ?= 4
P ?= 4

# ---- stimulus controls ----
NRAND ?= 40
NMAX  ?= 64
PEAK  ?= 2048
SEED  ?= 0x0D14C0DEC0DE0D14

# ---- tools ----
CC       ?= cc
CFLAGS   ?= -std=c11 -O2 -Wall -Wextra
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

RTL   := $(wildcard rtl/*.v)
TB    := tb/arc_tb.sv
VEC   := tb/vectors
CONST := $(VEC)/arc_const.vh
MEM   := $(VEC)/mem_init.hex
HOST  := sw/arc_host
SIM   := results/arc_sim.vvp

.PHONY: all sim sw vectors metrics elab synth clean

all: sim metrics

# ---------------- software: host / driver / reference / baseline ------------
$(HOST): sw/arc_host.c sw/arc_ref.c sw/arc_baseline.c sw/arc_driver.c sw/arc.h
	$(CC) $(CFLAGS) -DARC_R=$(R) -DARC_P=$(P) -c -o /dev/null sw/arc_driver.c   # firmware build check
	$(CC) $(CFLAGS) -DARC_R=$(R) -DARC_P=$(P) -o $@ sw/arc_host.c sw/arc_ref.c sw/arc_baseline.c

sw: $(HOST)

# ---------------- test vectors + golden + params ----------------------------
$(MEM): $(HOST)
	@mkdir -p $(VEC)
	./$(HOST) --nrand $(NRAND) --nmax $(NMAX) --peak $(PEAK) --seed $(SEED) --outdir $(VEC)

$(CONST): $(MEM)

vectors: $(MEM)

# ---------------- simulation ------------------------------------------------
$(SIM): $(RTL) $(TB) $(CONST)
	@mkdir -p results
	$(IVERILOG) -g2012 -o $@ -s arc_tb -I$(VEC) \
	    -Parc_collective_top.R=$(R) -Parc_collective_top.P=$(P) \
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
	   yosys -q -p "read_verilog $(RTL); hierarchy -top arc_collective_top; synth -top arc_collective_top; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --r $(R) --p $(P) ; \
	 fi

clean:
	rm -f $(HOST) $(SIM) results/elab_*.vvp
	rm -f $(VEC)/*.hex $(VEC)/arc_const.vh $(VEC)/sw_metrics.txt $(VEC)/golden.txt
	rm -f results/*.vcd results/sim.log results/metrics.md
