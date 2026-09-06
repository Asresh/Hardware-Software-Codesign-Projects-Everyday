# Author: Asresh
IVERILOG ?= iverilog
VVP ?= vvp
CC ?= cc
CFLAGS = -std=c11 -O2 -Wall -Wextra -Werror
RTL = rtl/coh_request_fifo.v rtl/probe_mask_filter.v rtl/coh_irq_latch.v rtl/coh_directory_bank.v rtl/coherent_snoop_filter_top.v

.PHONY: all sw sim synth check clean
all: check synth

sw:
	@mkdir -p build
	$(CC) $(CFLAGS) -o build/coherent_host sw/coherent_snoop_driver.c sw/coherent_snoop_reference.c sw/coherent_snoop_host.c
	./build/coherent_host

sim:
	@mkdir -p build
	$(IVERILOG) -g2012 -Wall -s coherent_snoop_filter_tb -o build/simv $(RTL) tb/coherent_snoop_filter_tb.v
	$(VVP) build/simv | tee build/sim.log

synth:
	@mkdir -p build
	@if command -v yosys >/dev/null 2>&1; then yosys -q -p 'read_verilog $(RTL); hierarchy -top coherent_snoop_filter_top; proc; opt; check; stat' | tee build/synth.log; else echo 'Yosys unavailable; running synthesis-oriented Icarus elaboration' | tee build/synth.log; $(IVERILOG) -g2012 -Wall -s coherent_snoop_filter_top -o build/synth_elab $(RTL); fi

check: sw sim
	$(CC) -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer -o build/coherent_san sw/coherent_snoop_driver.c sw/coherent_snoop_reference.c sw/coherent_snoop_host.c
	ASAN_OPTIONS=detect_leaks=0 ./build/coherent_san

clean:
	rm -rf build
