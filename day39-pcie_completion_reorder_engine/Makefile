# Author: Asresh
IVERILOG ?= iverilog
VVP ?= vvp
CC ?= cc
SHELL := /bin/bash
CFLAGS = -std=c11 -O2 -Wall -Wextra -Werror
RTL = rtl/pcie_tag_allocator.v rtl/pcie_order_fifo.v rtl/pcie_completion_store.v rtl/pcie_completion_reorder_engine.v
.PHONY: all sim sw synth check clean
all: check sim synth
sim:
	@mkdir -p build
	$(IVERILOG) -g2012 -Wall -s pcie_completion_reorder_engine_tb -o build/simv $(RTL) tb/pcie_completion_reorder_engine_tb.v
	set -o pipefail; $(VVP) build/simv | tee build/sim.log
sw:
	@mkdir -p build
	$(CC) $(CFLAGS) -o build/pcie_reorder_host sw/pcie_reorder_driver.c sw/pcie_reorder_reference.c sw/pcie_reorder_host.c
	set -o pipefail; ./build/pcie_reorder_host | tee build/sw.log
synth:
	@mkdir -p build
	@if command -v yosys >/dev/null 2>&1; then yosys -q -p 'read_verilog $(RTL); hierarchy -top pcie_completion_reorder_engine; proc; opt; check; stat' | tee build/synth.log; else echo 'Yosys unavailable; running synthesis-oriented Icarus elaboration' | tee build/synth.log; $(IVERILOG) -g2012 -Wall -s pcie_completion_reorder_engine -o build/synth_elab $(RTL); fi
check: sw
	$(CC) -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer -o build/pcie_reorder_san sw/pcie_reorder_driver.c sw/pcie_reorder_reference.c sw/pcie_reorder_host.c
	ASAN_OPTIONS=detect_leaks=0 ./build/pcie_reorder_san
clean:
	rm -rf build
