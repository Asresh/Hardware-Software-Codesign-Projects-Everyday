# =============================================================================
# Day 18 - multi-GPU kernel-DAG scheduler / hardware command processor
#   make sw      build the host / model / baseline / driver and emit vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make sweep   full differential simulation at four geometries
#   make synth   report datapath area (analytical; Yosys not present here)
#   make all     sw -> sim -> metrics
#   make clean   remove build artefacts
# =============================================================================

# ---- design parameters (RTL, golden model and testbench share them) ---------
NODES ?= 64
DEVS  ?= 4

# ---- tools -----------------------------------------------------------------
CC       ?= cc
CFLAGS   ?= -std=c11 -O2 -Wall -Wextra
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

CDEFS := -DKDS_MAX_NODES=$(NODES) -DKDS_DEVICES=$(DEVS)
VDEFS := -DKDS_MAX_NODES=$(NODES) -DKDS_DEVICES=$(DEVS)

RTL   := $(wildcard rtl/*.v)
TB    := tb/kds_tb.sv
VEC   := tb/vectors
CONST := $(VEC)/kds_const.vh
MEMH  := $(VEC)/mem_init.hex
HOST  := sw/kds_host
SIM   := results/kds_sim.vvp

.PHONY: all sim sw vectors metrics sweep elab synth clean

all: sim metrics

# ---------------- software: host / model / baseline / firmware ---------------
$(HOST): sw/kds_host.c sw/kds_model.c sw/kds_baseline.c sw/kds_driver.c sw/kds.h
	$(CC) $(CFLAGS) $(CDEFS) -c -o /dev/null sw/kds_driver.c   # firmware build check
	$(CC) $(CFLAGS) $(CDEFS) -o $@ sw/kds_host.c sw/kds_model.c sw/kds_baseline.c

sw: $(HOST)

# ---------------- test vectors + golden + params ----------------------------
$(MEMH): $(HOST)
	@mkdir -p $(VEC)
	./$(HOST) --outdir $(VEC)

$(CONST): $(MEMH)

vectors: $(MEMH)

# ---------------- simulation ------------------------------------------------
$(SIM): $(RTL) $(TB) $(CONST)
	@mkdir -p results
	$(IVERILOG) -g2012 $(VDEFS) -o $@ -s kds_tb -Irtl -I$(VEC) $(RTL) $(TB)

sim: vectors $(SIM)
	@mkdir -p results
	cd $(VEC) && $(VVP) ../../$(SIM) | tee ../../results/sim.log
	@if grep -q "TEST FAILED" results/sim.log; then echo "SIMULATION FAILED"; exit 1; fi
	@if ! grep -q "TEST PASSED" results/sim.log; then echo "NO PASS MARKER"; exit 1; fi

# ---------------- metrics ---------------------------------------------------
metrics:
	$(PYTHON) scripts/extract_metrics.py results/sim.log $(VEC)/sw_metrics.txt > results/metrics.md
	@echo "wrote results/metrics.md"

# ---------------- parameter sweep (full differential run per geometry) ------
sweep elab:
	@bash scripts/param_sweep.sh

# ---------------- synthesis / area ------------------------------------------
synth:
	@if command -v yosys >/dev/null 2>&1; then \
	   yosys -q -p "read_verilog -I rtl $(RTL); hierarchy -top kds_top; synth -top kds_top; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --nodes $(NODES) --devices $(DEVS) ; \
	 fi

clean:
	rm -f $(HOST) $(SIM)
	rm -rf results/sweep_*
	rm -f $(VEC)/mem_init.hex $(VEC)/golden_mem.hex $(VEC)/graphs.txt \
	      $(VEC)/kds_const.vh $(VEC)/sw_metrics.txt
	rm -f results/*.vcd results/sim.log results/metrics.md
