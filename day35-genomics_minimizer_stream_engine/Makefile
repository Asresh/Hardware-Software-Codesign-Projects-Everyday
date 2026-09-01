# Author: Asresh
IVERILOG ?= iverilog
VVP ?= vvp
CC ?= cc
CFLAGS = -std=c11 -O2 -Wall -Wextra -Werror
RTL = rtl/kmer_revcomp.v rtl/kmer_hash_mix.v rtl/min_window.v rtl/minimizer_irq_latch.v rtl/genomics_minimizer_top.v
.PHONY: all sim sw synth check clean
all: check sim synth
sim:
	@mkdir -p build
	$(IVERILOG) -g2012 -Wall -s genomics_minimizer_tb -o build/simv $(RTL) tb/genomics_minimizer_tb.v
	$(VVP) build/simv | tee build/sim.log
sw:
	@mkdir -p build
	$(CC) $(CFLAGS) -o build/minimizer_host sw/minimizer_driver.c sw/minimizer_model.c sw/minimizer_host.c
	./build/minimizer_host
synth:
	@mkdir -p build
	@if command -v yosys >/dev/null 2>&1; then yosys -q -p 'read_verilog $(RTL); hierarchy -top genomics_minimizer_top; proc; opt; check; stat' | tee build/synth.log; else echo 'Yosys unavailable; running synthesis-oriented Icarus elaboration' | tee build/synth.log; $(IVERILOG) -g2012 -Wall -s genomics_minimizer_top -o build/synth_elab $(RTL); fi
check: sw
	$(CC) -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer -o build/minimizer_san sw/minimizer_driver.c sw/minimizer_model.c sw/minimizer_host.c
	ASAN_OPTIONS=detect_leaks=0 ./build/minimizer_san
clean:
	rm -rf build
