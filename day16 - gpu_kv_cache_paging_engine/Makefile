# =============================================================================
# Day 16 - KV-cache paging engine (paged-attention block-table accelerator)
#   make sw      build host/model/baseline/driver and generate vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make sweep   full differential simulation at four cache geometries
#   make synth   report state/comparator area (analytical; Yosys not present)
#   make all     sw -> sim -> metrics
#   make clean   remove build artifacts
# =============================================================================

# ---- design parameters (RTL and golden model are built from the same set) ----
SETS       ?= 16
WAYS       ?= 4
FREE_DEPTH ?= 512

# ---- tools ----
CC       ?= cc
CFLAGS   ?= -std=c11 -O2 -Wall -Wextra
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

DEFS  := -DKVP_SETS=$(SETS) -DKVP_WAYS=$(WAYS) -DKVP_FREE_DEPTH=$(FREE_DEPTH)
RTL   := $(wildcard rtl/*.v)
TB    := tb/kvp_tb.sv
VEC   := tb/vectors
CONST := $(VEC)/kvp_const.vh
MEMH  := $(VEC)/mem_init.hex
HOST  := sw/kvp_host
SIM   := results/kvp_sim.vvp

.PHONY: all sim sw vectors metrics sweep elab synth clean check

all: sim metrics

# ---------------- software: host / model / baseline / firmware ---------------
$(HOST): sw/kvp_host.c sw/kvp_model.c sw/kvp_baseline.c sw/kvp_driver.c sw/kvp.h
	$(CC) $(CFLAGS) $(DEFS) -c -o /dev/null sw/kvp_driver.c   # firmware build check
	$(CC) $(CFLAGS) $(DEFS) -o $@ sw/kvp_host.c sw/kvp_model.c sw/kvp_baseline.c

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
	$(IVERILOG) -g2012 -o $@ -s kvp_tb -Irtl -I$(VEC) $(RTL) $(TB)

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
	   yosys -q -p "read_verilog -I rtl $(RTL); hierarchy -top kvp_top; synth -top kvp_top; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --sets $(SETS) --ways $(WAYS) \
	         --free-depth $(FREE_DEPTH) ; \
	 fi

# ---------------- sanitizer gate ---------------------------------------------
# Rebuilds the host / model / baseline with UBSan + ASan and regenerates the
# vectors through them. This exists because the work happens on clang and CI
# runs gcc: clang wraps signed overflow quietly, gcc -O2 treats it as a licence
# to drop a loop bound, and the difference between those two is an
# out-of-bounds write that only ever shows up in CI. -fno-sanitize-recover
# makes the first finding a non-zero exit, so this is a gate and not a report.
# Leak detection is off: these generators are one-shot and exit without freeing
# on purpose, which is not the defect class this is guarding against.
SAN_FLAGS ?= -O1 -g -fno-omit-frame-pointer \
             -fsanitize=undefined,address -fno-sanitize-recover=all
SAN_ENV   ?= ASAN_OPTIONS=detect_leaks=0

check:
	@rm -rf $(HOST) $(HOST).dSYM
	$(SAN_ENV) $(MAKE) vectors CFLAGS="$(CFLAGS) $(SAN_FLAGS)"
	@rm -rf $(HOST) $(HOST).dSYM
	@echo "sanitizer check clean: $@ ($(HOST))"

clean:
	rm -f $(HOST) $(SIM)
	rm -rf results/sweep_*
	rm -f $(VEC)/mem_init.hex $(VEC)/golden_res.hex $(VEC)/golden_bt.hex \
	      $(VEC)/batches.txt $(VEC)/kvp_const.vh $(VEC)/sw_metrics.txt
	rm -f results/*.vcd results/sim.log results/metrics.md
