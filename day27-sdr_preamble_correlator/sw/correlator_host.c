/* Author: Asresh */
#include "correlator.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VECTOR_COUNT 320u
#define THRESHOLD UINT64_C(100000000)

struct mock_hw { uint32_t regs[32]; size_t moved; };

static uint32_t rng_state = UINT32_C(0x27c0ffee);
static uint32_t random_u32(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}
static void mock_write(void *ctx, uint32_t addr, uint32_t value) {
    struct mock_hw *hw = ctx;
    if ((addr >> 2) < 32u)
        hw->regs[addr >> 2] = value;
    if (addr == CORR_IRQ_ACK)
        hw->regs[CORR_STATUS >> 2] &= ~2u;
}
static uint32_t mock_read(void *ctx, uint32_t addr) {
    struct mock_hw *hw = ctx;
    return (addr >> 2) < 32u ? hw->regs[addr >> 2] : 0u;
}
static int mock_stream(void *ctx, const struct corr_vector *vectors, size_t count) {
    struct mock_hw *hw = ctx;
    if (vectors == NULL || count == 0u || vectors[count - 1u].last == 0u)
        return -1;
    hw->moved += count * sizeof(*vectors);
    hw->regs[CORR_STATUS >> 2] |= 2u;
    return 0;
}
static void fill_vector(struct corr_vector *v,
                        const struct corr_complex8 taps[CORR_LANES], size_t n) {
    size_t lane;
    v->tag = (uint16_t)n;
    v->last = n + 1u == VECTOR_COUNT;
    for (lane = 0; lane < CORR_LANES; ++lane) {
        if (n == 0u) {
            v->sample[lane].i = 0;
            v->sample[lane].q = 0;
        } else if (n == 1u || (n % 31u) == 0u) {
            v->sample[lane] = taps[lane];
        } else if (n == 2u) {
            v->sample[lane].i = INT8_MAX;
            v->sample[lane].q = INT8_MIN;
        } else {
            v->sample[lane].i = (int8_t)(random_u32() & 0xffu);
            v->sample[lane].q = (int8_t)(random_u32() & 0xffu);
        }
    }
}

int main(int argc, char **argv) {
    static const struct corr_complex8 taps[CORR_LANES] = {
        {37, -11}, {-23, 41}, {55, 17}, {-61, -7},
        {19, 63}, {-45, 29}, {71, -33}, {-13, -57}
    };
    struct corr_vector vectors[VECTOR_COUNT];
    struct mock_hw hw;
    struct corr_device dev;
    char path[512];
    FILE *fp;
    size_t n, lane;
    if (argc != 2) {
        fprintf(stderr, "usage: %s VECTOR_DIR\n", argv[0]);
        return 2;
    }
    memset(&hw, 0, sizeof(hw));
    dev.ctx = &hw; dev.write32 = mock_write; dev.read32 = mock_read; dev.stream = mock_stream;
    for (n = 0; n < VECTOR_COUNT; ++n)
        fill_vector(&vectors[n], taps, n);
    corr_configure(&dev, taps, THRESHOLD);
    if (corr_submit(&dev, vectors, VECTOR_COUNT, 100u) != 0 || hw.moved == 0u)
        return 3;
    corr_handle_irq(&dev);

    if (snprintf(path, sizeof(path), "%s/vectors.txt", argv[1]) >= (int)sizeof(path))
        return 4;
    fp = fopen(path, "w");
    if (fp == NULL) { perror(path); return 5; }
    fprintf(fp, "%u %" PRIx64 "\n", VECTOR_COUNT, THRESHOLD);
    for (lane = 0; lane < CORR_LANES; ++lane)
        fprintf(fp, "%02x %02x%c", (uint8_t)taps[lane].i,
                (uint8_t)taps[lane].q, lane + 1u == CORR_LANES ? '\n' : ' ');
    for (n = 0; n < VECTOR_COUNT; ++n) {
        uint32_t word[4] = {0, 0, 0, 0};
        const uint64_t power = corr_reference(vectors[n].sample, taps);
        for (lane = 0; lane < CORR_LANES; ++lane) {
            const uint32_t packed = (uint8_t)vectors[n].sample[lane].i |
                                    ((uint32_t)(uint8_t)vectors[n].sample[lane].q << 8);
            word[lane / 2u] |= packed << ((lane % 2u) * 16u);
        }
        fprintf(fp, "%04x %u %08x %08x %08x %08x %011" PRIx64 " %u\n",
                vectors[n].tag, vectors[n].last, word[3], word[2], word[1], word[0],
                power, power >= THRESHOLD);
    }
    if (fclose(fp) != 0) return 6;
    printf("generated %u vectors, scalar baseline cycles=%" PRIu64 "\n",
           VECTOR_COUNT, corr_baseline_cycles(VECTOR_COUNT));
    return 0;
}
