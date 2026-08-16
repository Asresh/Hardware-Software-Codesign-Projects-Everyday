// Author: Asresh
// Deterministic corner/random vector generator shared by model, baseline and RTL testbench.
#include "motor_current.h"
#include <errno.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

static uint32_t rng_state = UINT32_C(0x25c0de15);
static uint32_t next_random(void) {
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}
static int16_t random_i16(void) {
    int32_t x = (int32_t)(next_random() & UINT32_C(0xffff));
    if (x >= 32768) x -= 65536;
    return (int16_t)x;
}
static void emit(FILE *f, int16_t ref, int16_t meas, uint8_t gain,
                 uint16_t trip, int fault, uint64_t *baseline) {
    const struct mc_result result = mc_reference(ref, meas, gain, trip, fault);
    const uint32_t cost = mc_baseline_cycles(ref, meas, gain, trip, fault);
    *baseline += cost;
    fprintf(f, "%d %d %u %u %d %u %u %u\n", ref, meas, gain, trip,
            fault, result.duty, result.flags, cost);
}

int main(int argc, char **argv) {
    char path[1024];
    FILE *f;
    uint64_t baseline = 0;
    unsigned i;
    if (argc != 2) {
        fprintf(stderr, "usage: %s output-directory\n", argv[0]);
        return 2;
    }
    if (snprintf(path, sizeof(path), "%s/vectors.txt", argv[1]) >= (int)sizeof(path)) return 2;
    f = fopen(path, "w");
    if (f == NULL) {
        fprintf(stderr, "open %s: errno %d\n", path, errno);
        return 1;
    }
    fprintf(f, "320\n");
    emit(f, 0, 0, 64, 30000, 0, &baseline);
    emit(f, INT16_MAX, INT16_MIN, 255, UINT16_MAX, 0, &baseline);
    emit(f, INT16_MIN, INT16_MAX, 255, UINT16_MAX, 0, &baseline);
    emit(f, 12000, 12000, 0, 30000, 0, &baseline);
    emit(f, 1000, 30001, 96, 30000, 0, &baseline);
    emit(f, -1000, -30001, 96, 30000, 0, &baseline);
    emit(f, 20000, -20000, 255, UINT16_MAX, 1, &baseline);
    emit(f, -20000, 20000, 255, UINT16_MAX, 0, &baseline);
    for (i = 8; i < 320; ++i) {
        const int16_t ref = random_i16();
        const int16_t meas = random_i16();
        const uint8_t gain = (uint8_t)(next_random() & 255u);
        const uint16_t trip = (uint16_t)(1000u + (next_random() % 31768u));
        const int fault = ((next_random() % 41u) == 0u);
        emit(f, ref, meas, gain, trip, fault, &baseline);
    }
    fclose(f);
    printf("generated 320 vectors, scalar baseline cycles=%llu\n", (unsigned long long)baseline);
    return 0;
}
