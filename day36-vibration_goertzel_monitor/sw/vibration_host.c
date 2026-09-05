/* Author: Asresh */
#include "vibration_monitor.h"
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
static uint32_t rng = 0x36c0deu;
static uint32_t next_u32(void) { rng = rng * 1664525u + 1013904223u; return rng; }
int main(void) {
    volatile uint32_t regs[16];
    int16_t coeff[4] = {362, 256, 0, -256};
    int16_t samples[64];
    uint64_t checksum = 0;
    memset((void *)regs, 0, sizeof regs);
    vm_configure(regs, coeff);
    for (unsigned frame = 0; frame < 260; ++frame) {
        for (unsigned n = 0; n < 64; ++n) samples[n] = (int16_t)((int32_t)(next_u32() & 2047u) - 1024);
        if (frame == 0) memset(samples, 0, sizeof samples);
        if (frame == 1) { memset(samples, 0, sizeof samples); samples[0] = 2047; }
        if (frame == 2) for (unsigned n = 0; n < 64; ++n) samples[n] = (n & 1u) ? -2048 : 2047;
        if (frame == 3) for (unsigned n = 0; n < 64; ++n) samples[n] = 2047;
        struct vm_result ref;
        vm_reference(samples, 64, coeff, &ref);
        checksum ^= ref.power + ((uint64_t)ref.bin << (frame & 31u));
    }
    if (regs[VM_CTRL] != 1u || (int16_t)regs[VM_COEFF0+3] != -256) return 1;
    printf("software: 260 frames, 16640 samples, reference checksum 0x%016" PRIx64 "\n", checksum);
    return 0;
}
