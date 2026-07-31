# =============================================================================
# Day 10 - GPU/FPGA bit-pack columnar decode engine
#   make sw      build host/driver/reference/baseline and generate vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make elab    elaborate the RTL at three distinct parameter sets
#   make synth   report flop/LUT area (analytical; Yosys not present here)
#   make all     sw -> sim -> metrics
#   make clean   remove build artifacts
# =============================================================================

# ---- design parameters ----
LANES ?= 4

# ---- stimulus controls ----
NRAND ?= 256
SEED  ?= 0x0BADC0DE

# ---- tools ----
CC       ?= cc
CFLAGS   ?= -std=c11 -O2 -Wall -Wextra -DLANES=$(LANES)
IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

RTL   := $(wildcard rtl/*.v)
TB    := tb/bpd_tb.sv
VEC   := tb/vectors
CONST := $(VEC)/bpd_const.vh
ING   := $(VEC)/ingress.hex
HOST  := sw/bpd_host
SIM   := results/bpd_sim.vvp

.PHONY: all sim sw vectors metrics elab synth clean

all: sim metrics

# ---------------- software: host / driver / reference / baseline ----------------
$(HOST): sw/bpd_host.c sw/bpd_ref.c sw/bpd_baseline.c sw/bpd_driver.c sw/bpd.h
	$(CC) $(CFLAGS) -c -o /dev/null sw/bpd_driver.c        # firmware build check
	$(CC) $(CFLAGS) -o $@ sw/bpd_host.c sw/bpd_ref.c sw/bpd_baseline.c

sw: $(HOST)

# ---------------- test vectors + golden + params ----------------
$(ING): $(HOST)
	@mkdir -p $(VEC)
	./$(HOST) --nrand $(NRAND) --seed $(SEED) --outdir $(VEC)

$(CONST): $(ING)

vectors: $(ING)

# ---------------- simulation ----------------
$(SIM): $(RTL) $(TB) $(CONST)
	@mkdir -p results
	$(IVERILOG) -g2012 -o $@ -s bpd_tb -I$(VEC) $(RTL) $(TB)

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
	   yosys -q -p "read_verilog $(RTL); hierarchy -top bitpack_decode_engine; synth -top bitpack_decode_engine; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --lanes $(LANES) ; \
	 fi

clean:
	rm -f $(HOST) $(SIM)
	rm -f $(VEC)/*.hex $(VEC)/bpd_const.vh $(VEC)/sw_metrics.txt
	rm -f results/*.vcd results/sim.log results/metrics.md
