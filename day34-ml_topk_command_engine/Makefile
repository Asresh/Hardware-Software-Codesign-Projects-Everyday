# Author: Asresh
CC ?= cc
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Werror -Wformat=2 -Wformat-security -fstack-protector-strong
IVERILOG ?= iverilog
VVP ?= vvp
HOST := sw/topk_host
SRC := sw/topk_host.c sw/topk_model.c sw/topk_baseline.c sw/topk_driver.c
RTL := $(wildcard rtl/*.v)
SIM := results/ml_topk_sim.vvp
VEC := tb/vectors.txt
.PHONY: all sw vectors sim synth check clean
all: sim
$(HOST): $(SRC) sw/ml_topk.h
	$(CC) $(CFLAGS) -o $@ $(SRC)
sw: $(HOST)
$(VEC): $(HOST)
	./$(HOST)
vectors: $(VEC)
$(SIM): $(RTL) tb/ml_topk_command_tb.v
	@mkdir -p results
	$(IVERILOG) -g2012 -Wall -o $@ -s ml_topk_command_tb $(RTL) tb/ml_topk_command_tb.v
sim: vectors $(SIM)
	cd tb && $(VVP) ../$(SIM) | tee ../results/sim.log
	@if grep -q "TEST FAILED" results/sim.log; then exit 1; fi
	@grep -q "TEST PASSED" results/sim.log
synth:
	@if command -v yosys >/dev/null 2>&1; then yosys -q -p "read_verilog $(RTL); hierarchy -top ml_topk_command_top; synth -top ml_topk_command_top; stat"; else echo "yosys not found - running Icarus synthesis-oriented elaboration"; $(IVERILOG) -g2012 -tnull -s ml_topk_command_top $(RTL); fi

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
	rm -f $(HOST) $(SIM) results/sim.log $(VEC)
	rm -rf $(HOST).dSYM
