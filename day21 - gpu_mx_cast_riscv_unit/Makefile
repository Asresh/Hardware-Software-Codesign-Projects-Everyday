# =============================================================================
# Day 21 - MX-cast custom functional unit on an RV32I core
#   make sw      build the host / model / baseline / firmware and emit vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make sweep   full differential simulation at five geometries
#   make mutate  inject defects and confirm the testbench catches them
#   make check   rebuild the C side under UBSan/ASan and regenerate the vectors
#   make synth   report datapath area (analytical; Yosys not present here)
#   make all     sw -> sim -> metrics
#   make clean   remove build artefacts
# =============================================================================

# ---- design parameters (RTL, golden model and testbench share them) ---------
IMEM_W ?= 12
DMEM_W ?= 12
BLK    ?= 32

# ---- tools ------------------------------------------------------------------
CC       ?= cc
CFLAGS   ?= -std=c11 -O2 -Wall -Wextra
LDLIBS   ?= -lm
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

CDEFS := -DMXQ_IMEM_W=$(IMEM_W) -DMXQ_DMEM_W=$(DMEM_W) -DMXQ_BLK=$(BLK)
VDEFS := -DMXQ_IMEM_W=$(IMEM_W) -DMXQ_DMEM_W=$(DMEM_W)

RTL   := $(wildcard rtl/*.v)
TB    := tb/mxq_tb.sv
VEC   := tb/vectors
CONST := $(VEC)/mxq_const.vh
JOBS  := $(VEC)/jobs.hex
HOST  := sw/mxq_host
SIM   := results/mxq_sim.vvp
SRC   := sw/mxq_host.c sw/mxq_model.c sw/mxq_baseline.c sw/mxq_iss.c \
         sw/mxq_asm.c sw/mxq_kernels.c

.PHONY: all sim sw vectors metrics sweep mutate elab synth clean check

all: sim metrics

# ---------------- software: host / model / baseline / firmware ---------------
$(HOST): $(SRC) sw/mxq.h sw/mxq_asm.h sw/mxq_driver.c
	$(CC) $(CFLAGS) $(CDEFS) -c -o /dev/null sw/mxq_driver.c   # firmware build check
	$(CC) $(CFLAGS) $(CDEFS) -o $@ $(SRC) $(LDLIBS)

sw: $(HOST)

# ---------------- test vectors + golden + params -----------------------------
$(JOBS): $(HOST)
	@mkdir -p $(VEC)
	./$(HOST) --outdir $(VEC)

$(CONST): $(JOBS)

vectors: $(JOBS)

# ---------------- simulation -------------------------------------------------
$(SIM): $(RTL) $(TB) $(CONST)
	@mkdir -p results
	$(IVERILOG) -g2012 $(VDEFS) -o $@ -s mxq_tb -Irtl -I$(VEC) $(RTL) $(TB)

sim: vectors $(SIM)
	@mkdir -p results
	cd $(VEC) && $(VVP) ../../$(SIM) | tee ../../results/sim.log
	@if grep -q "TEST FAILED" results/sim.log; then echo "SIMULATION FAILED"; exit 1; fi
	@if ! grep -q "TEST PASSED" results/sim.log; then echo "NO PASS MARKER"; exit 1; fi

# ---------------- metrics ----------------------------------------------------
metrics:
	$(PYTHON) scripts/extract_metrics.py results/sim.log $(VEC)/sw_metrics.txt \
	    $(IMEM_W) $(DMEM_W) $(BLK) > results/metrics.md
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
	   yosys -q -p "read_verilog -I rtl $(RTL); hierarchy -top mxq_top; synth -top mxq_top; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --imem $(IMEM_W) --dmem $(DMEM_W) ; \
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
	rm -rf results/sweep_* results/mutant_* $(HOST).dSYM
	rm -f $(VEC)/*.hex $(VEC)/mxq_const.vh $(VEC)/sw_metrics.txt
	rm -f results/*.vcd results/sim.log results/metrics.md
