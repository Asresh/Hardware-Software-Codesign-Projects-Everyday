# =============================================================================
# Day 12 - GPU/FPGA line-rate pre-trade risk / market-access gateway
#   make sw      build host/driver/reference/baseline and generate vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make elab    elaborate the RTL at three distinct parameter sets
#   make synth   report flop/LUT area (analytical; Yosys not present here)
#   make all     sw -> sim -> metrics
#   make clean   remove build artifacts
# =============================================================================

# ---- design parameters ----
SYM_N  ?= 32
ACCT_N ?= 8

# ---- stimulus controls ----
NRAND ?= 300
SEED  ?= 0x0BADC0DE

# ---- tools ----
CC       ?= cc
CFLAGS   ?= -std=c11 -O2 -Wall -Wextra
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

RTL   := $(wildcard rtl/*.v)
TB    := tb/risk_tb.sv
VEC   := tb/vectors
CONST := $(VEC)/risk_const.vh
ORD   := $(VEC)/orders.hex
HOST  := sw/risk_host
SIM   := results/risk_sim.vvp

.PHONY: all sim sw vectors metrics elab synth clean check

all: sim metrics

# ---------------- software: host / driver / reference / baseline ----------------
$(HOST): sw/risk_host.c sw/risk_ref.c sw/risk_baseline.c sw/risk_driver.c sw/risk.h
	$(CC) $(CFLAGS) -c -o /dev/null sw/risk_driver.c          # firmware build check
	$(CC) $(CFLAGS) -o $@ sw/risk_host.c sw/risk_ref.c sw/risk_baseline.c

sw: $(HOST)

# ---------------- test vectors + golden + params ----------------
$(ORD): $(HOST)
	@mkdir -p $(VEC)
	./$(HOST) --nrand $(NRAND) --seed $(SEED) --outdir $(VEC)

$(CONST): $(ORD)

vectors: $(ORD)

# ---------------- simulation ----------------
$(SIM): $(RTL) $(TB) $(CONST)
	@mkdir -p results
	$(IVERILOG) -g2012 -o $@ -s risk_tb -I$(VEC) \
	    -Ppretrade_risk_engine.SYM_N=$(SYM_N) -Ppretrade_risk_engine.ACCT_N=$(ACCT_N) \
	    $(RTL) $(TB)

sim: vectors $(SIM)
	@mkdir -p results
	cd $(VEC) && $(VVP) ../../$(SIM) | tee ../../results/sim.log
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
synth:
	@if command -v yosys >/dev/null 2>&1; then \
	   yosys -q -p "read_verilog $(RTL); hierarchy -top pretrade_risk_engine; synth -top pretrade_risk_engine; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --sym_n $(SYM_N) --acct_n $(ACCT_N) ; \
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
	rm -f $(HOST) $(SIM) results/elab_*.vvp
	rm -f $(VEC)/*.hex $(VEC)/risk_const.vh $(VEC)/sw_metrics.txt $(VEC)/golden.txt
	rm -f results/*.vcd results/sim.log results/metrics.md
