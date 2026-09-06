# Author: Asresh
IVERILOG ?= iverilog
VVP ?= vvp
CC ?= cc
CFLAGS = -std=c11 -O2 -Wall -Wextra -Werror
RTL = rtl/tile_popcount8.v rtl/tile_byte_scan.v rtl/tile_mask_reduce.v rtl/gpu_tile_mask_compactor.v
.PHONY: all sim sw synth check clean
all: check sim synth
sim:
	@mkdir -p build
	$(IVERILOG) -g2012 -Wall -s gpu_tile_mask_compactor_tb -o build/simv $(RTL) tb/gpu_tile_mask_compactor_tb.v
	$(VVP) build/simv | tee build/sim.log
sw:
	@mkdir -p build
	$(CC) $(CFLAGS) -o build/gpu_tile_host sw/gpu_tile_driver.c sw/gpu_tile_reference.c sw/gpu_tile_host.c
	./build/gpu_tile_host | tee build/sw.log
synth:
	@mkdir -p build
	@if command -v yosys >/dev/null 2>&1; then yosys -q -p 'read_verilog $(RTL); hierarchy -top gpu_tile_mask_compactor; proc; opt; check; stat' | tee build/synth.log; else echo 'Yosys unavailable; running synthesis-oriented Icarus elaboration' | tee build/synth.log; $(IVERILOG) -g2012 -Wall -s gpu_tile_mask_compactor -o build/synth_elab $(RTL); fi
check: sw
	$(CC) -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer -o build/gpu_tile_san sw/gpu_tile_driver.c sw/gpu_tile_reference.c sw/gpu_tile_host.c
	ASAN_OPTIONS=detect_leaks=0 ./build/gpu_tile_san
clean:
	rm -rf build
