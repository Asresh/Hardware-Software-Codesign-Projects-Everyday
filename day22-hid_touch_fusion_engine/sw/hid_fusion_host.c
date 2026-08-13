#include "hid_fusion.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t rng_state = 0x22c0ffeeu;
static uint32_t next_random(void)
{
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

static void emit(FILE *fp, const uint16_t s[HIDF_CHANNELS], uint16_t baseline,
                 uint32_t threshold)
{
    struct hidf_result r;
    size_t i;
    hidf_reference(s, baseline, threshold, &r);
    for (i = 0; i < HIDF_CHANNELS; ++i)
        fprintf(fp, "%04x ", s[i]);
    fprintf(fp, "%04x %04x %08x %02x\n", r.x, r.y, r.pressure, r.flags);
}

int main(int argc, char **argv)
{
    const uint16_t baseline = 100u;
    const uint32_t threshold = 80u;
    uint16_t s[HIDF_CHANNELS] = {0};
    FILE *fp;
    unsigned i, j;

    if (argc != 2) {
        fprintf(stderr, "usage: %s OUTDIR\n", argv[0]);
        return 2;
    }
    {
        char path[1024];
        int n = snprintf(path, sizeof path, "%s/vectors.txt", argv[1]);
        if (n < 0 || (size_t)n >= sizeof path)
            return 2;
        fp = fopen(path, "w");
    }
    if (fp == NULL) {
        fprintf(stderr, "open vectors: %s\n", strerror(errno));
        return 2;
    }
    fprintf(fp, "304 %u %u\n", baseline, threshold);

    emit(fp, s, baseline, threshold);
    for (j = 0; j < HIDF_CHANNELS; ++j) s[j] = baseline;
    emit(fp, s, baseline, threshold);
    memset(s, 0, sizeof s); s[0] = 65535u; emit(fp, s, baseline, threshold);
    memset(s, 0, sizeof s); s[3] = 65535u; emit(fp, s, baseline, threshold);
    for (j = 0; j < HIDF_CHANNELS; ++j) s[j] = 65535u;
    emit(fp, s, baseline, threshold);

    for (i = 5; i < 304u; ++i) {
        for (j = 0; j < HIDF_CHANNELS; ++j) {
            uint32_t r = next_random();
            s[j] = (i % 17u == 0u) ? (uint16_t)(r & 127u) : (uint16_t)r;
        }
        emit(fp, s, baseline, threshold);
    }
    if (fclose(fp) != 0)
        return 2;

    printf("generated 304 frames; scalar baseline %u cycles/frame\n",
           hidf_baseline_cycles());
    return 0;
}
