# Author: Asresh
# Flow: C model -> vectors -> RTL simulation -> measured report
CC ?= cc
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Werror
IVERILOG ?= iverilog
VVP ?= vvp
PYTHON ?= python3
HOST := sw/usb_audio_host
SRC := sw/usb_audio_host.c sw/usb_audio_model.c sw/usb_audio_baseline.c
RTL := $(wildcard rtl/*.v)
SIM := results/usb_audio_sim.vvp
VEC := tb/vectors/vectors.txt
.PHONY: all sw vectors sim metrics synth check clean
all: sim metrics
$(HOST): $(SRC) sw/usb_audio.h sw/usb_audio_driver.c
	$(CC) $(CFLAGS) -c -o /dev/null sw/usb_audio_driver.c
	$(CC) $(CFLAGS) -o $@ $(SRC)
sw: $(HOST)
$(VEC): $(HOST)
	@mkdir -p tb/vectors
	./$(HOST) tb/vectors
vectors: $(VEC)
$(SIM): $(RTL) tb/usb_audio_rate_matcher_tb.sv
	@mkdir -p results
	$(IVERILOG) -g2012 -Wall -o $@ -s usb_audio_rate_matcher_tb $(RTL) tb/usb_audio_rate_matcher_tb.sv
sim: vectors $(SIM)
	cd tb/vectors && $(VVP) ../../$(SIM) | tee ../../results/sim.log
	@if grep -q "TEST FAILED" results/sim.log; then exit 1; fi
	@grep -q "TEST PASSED" results/sim.log
metrics: sim
	$(PYTHON) scripts/extract_metrics.py results/sim.log > results/metrics.md
synth:
	@if command -v yosys >/dev/null 2>&1; then yosys -q -p "read_verilog $(RTL); hierarchy -top usb_audio_mmio_top; synth -top usb_audio_mmio_top; stat"; else echo "yosys not found - running Icarus synthesis-oriented elaboration"; $(IVERILOG) -g2012 -tnull -s usb_audio_mmio_top $(RTL); fi

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
