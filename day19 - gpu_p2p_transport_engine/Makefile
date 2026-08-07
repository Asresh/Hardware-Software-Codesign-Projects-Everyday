# =============================================================================
# Day 19 - GPU-to-GPU peer transport engine
#   make sw      build the host / model / baseline / firmware and emit vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make sweep   full differential simulation at four geometries
#   make mutate  inject defects and confirm the testbench catches them
#   make synth   report datapath area (analytical; Yosys not present here)
#   make all     sw -> sim -> metrics
#   make clean   remove build artefacts
# =============================================================================

# ---- design parameters (RTL, golden model and testbench share them) ---------
MTU  ?= 16
QP   ?= 4
BUFS ?= 4

# ---- tools ------------------------------------------------------------------
CC       ?= cc
CFLAGS   ?= -std=c11 -O2 -Wall -Wextra
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

CDEFS := -DP2P_MTU_WORDS=$(MTU) -DP2P_NUM_QP=$(QP) -DP2P_RX_BUFS=$(BUFS)
VDEFS := -DP2P_MTU_WORDS=$(MTU) -DP2P_NUM_QP=$(QP) -DP2P_RX_BUFS=$(BUFS)

RTL   := $(wildcard rtl/*.v)
TB    := tb/p2p_tb.sv
VEC   := tb/vectors
CONST := $(VEC)/p2p_const.vh
MEMH  := $(VEC)/mem_init.hex
HOST  := sw/p2p_host
SIM   := results/p2p_sim.vvp

.PHONY: all sim sw vectors metrics sweep mutate elab synth clean check

all: sim metrics

# ---------------- software: host / model / baseline / firmware ---------------
$(HOST): sw/p2p_host.c sw/p2p_model.c sw/p2p_baseline.c sw/p2p_driver.c sw/p2p.h
	$(CC) $(CFLAGS) $(CDEFS) -c -o /dev/null sw/p2p_driver.c   # firmware build check
	$(CC) $(CFLAGS) $(CDEFS) -o $@ sw/p2p_host.c sw/p2p_model.c sw/p2p_baseline.c

sw: $(HOST)

# ---------------- test vectors + golden + params -----------------------------
$(MEMH): $(HOST)
	@mkdir -p $(VEC)
	./$(HOST) --outdir $(VEC)

$(CONST): $(MEMH)

vectors: $(MEMH)

# ---------------- simulation -------------------------------------------------
$(SIM): $(RTL) $(TB) $(CONST)
	@mkdir -p results
	$(IVERILOG) -g2012 $(VDEFS) -o $@ -s p2p_tb -Irtl -I$(VEC) $(RTL) $(TB)

sim: vectors $(SIM)
	@mkdir -p results
	cd $(VEC) && $(VVP) ../../$(SIM) | tee ../../results/sim.log
	@if grep -q "TEST FAILED" results/sim.log; then echo "SIMULATION FAILED"; exit 1; fi
	@if ! grep -q "TEST PASSED" results/sim.log; then echo "NO PASS MARKER"; exit 1; fi

# ---------------- metrics ----------------------------------------------------
metrics:
	$(PYTHON) scripts/extract_metrics.py results/sim.log $(VEC)/sw_metrics.txt \
	    $(MTU) $(QP) $(BUFS) > results/metrics.md
	@echo "wrote results/metrics.md"

# ---------------- parameter sweep (full differential run per geometry) -------
sweep elab:
	@bash scripts/param_sweep.sh

# ---------------- mutation check ---------------------------------------------
mutate: vectors
	@bash scripts/mutate.sh

# ---------------- synthesis / area -------------------------------------------
synth:
	@if command -v yosys >/dev/null 2>&1; then \
	   yosys -q -p "read_verilog -I rtl $(RTL); hierarchy -top p2p_top; synth -top p2p_top; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --mtu $(MTU) --qp $(QP) --bufs $(BUFS) ; \
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
	rm -rf results/sweep_* results/mutant_*
	rm -f $(VEC)/mem_init.hex $(VEC)/golden_mem.hex $(VEC)/runs.txt \
	      $(VEC)/p2p_const.vh $(VEC)/sw_metrics.txt
	rm -f results/*.vcd results/sim.log results/metrics.md
