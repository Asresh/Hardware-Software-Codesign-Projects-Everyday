# Author: Asresh
CC ?= cc
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Werror
IVERILOG ?= iverilog
VVP ?= vvp
PYTHON ?= python3
HOST := sw/eye_host
SRC := sw/eye_host.c sw/eye_model.c sw/eye_baseline.c
RTL := $(wildcard rtl/*.v)
SIM := results/eye_sim.vvp
VEC := tb/vectors.txt
.PHONY: all sw vectors sim metrics synth check clean
all: sim metrics
$(HOST): $(SRC) sw/eye_margin.h sw/eye_driver.c
	$(CC) $(CFLAGS) -c -o /dev/null sw/eye_driver.c
	$(CC) $(CFLAGS) -o $@ $(SRC) sw/eye_driver.c
sw: $(HOST)
$(VEC): $(HOST)
	./$(HOST) tb
vectors: $(VEC)
$(SIM): $(RTL) tb/serdes_eye_margin_tb.sv
	@mkdir -p results
	$(IVERILOG) -g2012 -Wall -o $@ -s serdes_eye_margin_tb $(RTL) tb/serdes_eye_margin_tb.sv
sim: vectors $(SIM)
	cd tb && $(VVP) ../$(SIM) | tee ../results/sim.log
	@if grep -q "TEST FAILED" results/sim.log; then exit 1; fi
	@grep -q "TEST PASSED" results/sim.log
metrics: sim
	$(PYTHON) scripts/extract_metrics.py results/sim.log > results/metrics.md
synth:
	@if command -v yosys >/dev/null 2>&1; then yosys -q -p "read_verilog $(RTL); hierarchy -top serdes_eye_margin_top; synth -top serdes_eye_margin_top; stat"; else echo "yosys not found - running Icarus synthesis-oriented elaboration"; $(IVERILOG) -g2012 -tnull -s serdes_eye_margin_top $(RTL); fi

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
	rm -f $(HOST) $(SIM) results/sim.log results/metrics.md $(VEC)
	rm -rf $(HOST).dSYM
