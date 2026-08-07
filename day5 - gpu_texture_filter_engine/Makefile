# =============================================================================
# Day 5 - GPU-style Bilinear Texture-Filter / Image-Resampler Engine
#   make sw      build host / driver / reference / baseline and generate vectors
#   make sim     run the Icarus differential testbench (default via `all`)
#   make metrics regenerate results/metrics.md from the run
#   make elab    elaborate the RTL at three distinct parameter sets
#   make synth   report cell/FF area (analytical; Yosys not present here)
#   make all     sw -> sim -> metrics
#   make clean   remove build artifacts
# =============================================================================

# ---- design parameters (single source of truth for RTL, SW and vectors) ----
WMAX       ?= 64
ADDR_WIDTH ?= 20
MEM_WORDS  ?= 65536

# ---- stimulus controls ----
NRAND      ?= 280
SEED       ?= 0x5EED0005

# ---- tools ----
CC        ?= cc
CFLAGS    ?= -std=c11 -O2 -Wall -Wextra
IVERILOG  ?= iverilog
VVP       ?= vvp
PYTHON    ?= python3

RTL      := $(wildcard rtl/*.v)
TB       := tb/tex_tb.sv
VEC      := tb/vectors
PARAMS   := $(VEC)/params.vh
JOBS     := $(VEC)/jobs.txt
HOST     := sw/tex_host
SIM      := results/tex_sim.vvp

.PHONY: all sim sw vectors metrics elab synth clean check

all: sim metrics

# ---------------- software: host / driver / reference / baseline ----------------
$(HOST): sw/tex_host.c sw/tex_ref.c sw/tex_baseline.c sw/tex_driver.c sw/tex_accel.h
	$(CC) $(CFLAGS) -c -o /dev/null sw/tex_driver.c      # firmware build check
	$(CC) $(CFLAGS) -o $@ sw/tex_host.c sw/tex_ref.c sw/tex_baseline.c

sw: $(HOST)

# ---------------- test vectors + golden + params ----------------
$(JOBS): $(HOST)
	@mkdir -p $(VEC)
	./$(HOST) --nrand $(NRAND) --seed $(SEED) --wmax $(WMAX) \
	          --addr-width $(ADDR_WIDTH) --mem-words $(MEM_WORDS) --outdir $(VEC)

$(PARAMS): $(JOBS)

vectors: $(JOBS)

# ---------------- simulation ----------------
$(SIM): $(RTL) $(TB) $(PARAMS)
	@mkdir -p results
	$(IVERILOG) -g2012 -Wall -o $@ -s tex_tb -I$(VEC) $(RTL) $(TB)

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
# analytical gate/flop estimate from the parameters instead (see README section).
synth:
	@if command -v yosys >/dev/null 2>&1; then \
	   yosys -q -p "read_verilog $(RTL); hierarchy -top tex_top; synth -top tex_top; stat" ; \
	 else \
	   echo "yosys not found - using analytical area estimate"; \
	   $(PYTHON) scripts/area_estimate.py --wmax $(WMAX) --addr-width $(ADDR_WIDTH) ; \
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
	rm -f $(VEC)/*.hex $(VEC)/jobs.txt $(VEC)/sw_metrics.txt $(PARAMS)
	rm -f results/*.vcd results/sim.log results/metrics.md
