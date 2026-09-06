/* Author: Asresh */
#include "coherent_snoop.h"
#include <inttypes.h>
#include <stdio.h>

static uint32_t step_lfsr(uint32_t value)
{
    return (value << 1) | (((value >> 31) ^ (value >> 21) ^
                            (value >> 1) ^ value) & 1u);
}

static unsigned popcount4(uint8_t value)
{
    return (unsigned)(value & 1u) + (unsigned)((value >> 1) & 1u) +
           (unsigned)((value >> 2) & 1u) + (unsigned)((value >> 3) & 1u);
}

int main(void)
{
    volatile uint32_t regs[9] = {0};
    struct coh_model model;
    struct coh_result result;
    uint32_t lfsr = 0x1aceb00cu;
    uint64_t checksum = 0;
    unsigned probes = 0;
    unsigned errors = 0;
    unsigned hits = 0;
    unsigned i;

    coh_model_reset(&model);
    coh_configure(regs, 1);
    for (i = 0; i < 320u; ++i) {
        unsigned opcode;
        unsigned source;
        uint16_t address;
        if (i < 8u) {
            static const uint8_t directed_op[8] = {0, 0, 1, 2, 3, 3, 1, 4};
            static const uint8_t directed_src[8] = {0, 1, 2, 2, 2, 2, 3, 0};
            static const uint16_t directed_addr[8] = {
                0x0000, 0x0000, 0x0000, 0x0000,
                0x0000, 0x0000, 0x0200, 0x0200
            };
            opcode = directed_op[i];
            source = directed_src[i];
            address = directed_addr[i];
        } else {
            lfsr = step_lfsr(lfsr);
            opcode = lfsr % 5u;
            lfsr = step_lfsr(lfsr);
            source = lfsr % COH_NODES;
            lfsr = step_lfsr(lfsr);
            address = (uint16_t)((lfsr & 0xffu) << 6);
        }
        result = coh_model_apply(&model, opcode, source, address);
        probes += popcount4(result.probe_mask);
        errors += result.error;
        hits += result.hit;
        checksum = (checksum * UINT64_C(1099511628211)) ^
                   ((uint64_t)result.hit << 24) ^
                   ((uint64_t)result.error << 20) ^
                   ((uint64_t)result.evicted << 16) ^
                   ((uint64_t)result.probe_mask << 8) ^ result.new_sharers;
    }
    coh_ack_irq(regs);
    printf("software: 320 transactions (8 corner + 312 randomized), "
           "%u hits, %u misses, %u probes, %u protocol errors, "
           "checksum 0x%016" PRIx64 "\n",
           hits, 320u - hits, probes, errors, checksum);
    return 0;
}
