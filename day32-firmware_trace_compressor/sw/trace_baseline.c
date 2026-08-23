/* Author: Asresh */
#include "trace_compressor.h"

uint64_t trace_scalar_cycles(const trace_record_t *input, size_t count)
{
    size_t i;
    uint64_t cycles = 18u;
    if (input == NULL || count == 0u) return 0u;
    cycles += 20u;
    for (i = 1u; i < count; ++i) {
        cycles += 20u; /* load, unpack, compare, branches, timestamp update */
        if ((uint16_t)(input[i - 1u] & 0xffffu) !=
            (uint16_t)(input[i] & 0xffffu))
            cycles += 12u; /* packet assembly and two 32-bit stores */
    }
    cycles += 12u;
    return cycles;
}
