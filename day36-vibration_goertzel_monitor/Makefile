# Author: Asresh
IVERILOG ?= iverilog
VVP ?= vvp
CC ?= cc
CFLAGS = -std=c11 -O2 -Wall -Wextra -Werror
RTL = rtl/axis_skid_buffer.v rtl/goertzel_bin.v rtl/power_peak_selector.v rtl/vibration_goertzel_top.v
.PHONY: all sim sw synth check clean
all: check synth
sim:
	@mkdir -p build
	$(IVERILOG) -g2012 -Wall -s vibration_goertzel_tb -o build/simv $(RTL) tb/vibration_goertzel_tb.v
	$(VVP) build/simv | tee build/sim.log
sw:
	@mkdir -p build
	$(CC) $(CFLAGS) -o build/vibration_host sw/vibration_driver.c sw/vibration_reference.c sw/vibration_host.c
	./build/vibration_host
check: sw sim
	$(CC) -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer -o build/vibration_san sw/vibration_driver.c sw/vibration_reference.c sw/vibration_host.c
	ASAN_OPTIONS=detect_leaks=0 ./build/vibration_san
synth:
	@mkdir -p build
	@if command -v yosys >/dev/null 2>&1; then yosys -q -p 'read_verilog $(RTL); hierarchy -top vibration_goertzel_top; proc; opt; check; stat' | tee build/synth.log; else echo 'Yosys unavailable; running synthesis-oriented Icarus elaboration' | tee build/synth.log; $(IVERILOG) -g2012 -Wall -s vibration_goertzel_top -o build/synth_elab $(RTL); fi
clean:
	rm -rf build
