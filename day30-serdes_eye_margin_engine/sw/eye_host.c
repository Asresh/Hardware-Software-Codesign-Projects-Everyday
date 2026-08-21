/* Author: Asresh */
#include "eye_margin.h"
#include <stdio.h>
#include <stdlib.h>
static uint32_t rng_state = UINT32_C(0x30e1a55a);
static uint32_t next_random(void) { rng_state = rng_state * UINT32_C(1664525) + UINT32_C(1013904223); return rng_state; }
static int emit_scan(FILE *fp, unsigned scan, size_t count, uint16_t limit, unsigned pattern, uint64_t *baseline) {
    struct eye_point points[EYE_MAX_POINTS];
    struct eye_result result;
    size_t i;
    if (count == 0 || count > EYE_MAX_POINTS) return -1;
    for (i = 0; i < count; ++i) {
        uint16_t errors;
        if (pattern == 0) {
            if (i < 4u || (i >= 5u && i <= 12u) || (i >= 23u && i <= 30u)) errors = limit;
            else if (i >= 14u && i <= 21u) errors = (uint16_t)((i & 1u) ? limit : limit + 1u);
            else errors = (uint16_t)(limit + 1u);
        } else errors = (uint16_t)(next_random() & UINT32_C(0xffff));
        points[i].phase = (uint8_t)i; points[i].errors = errors; points[i].last = (uint8_t)(i + 1u == count);
    }
    if (eye_reference(points, count, limit, &result) != 0) return -2;
    for (i = 0; i < count; ++i) {
        if (fprintf(fp, "%u %u %u %u %u %u %u %u\n", scan, limit, points[i].phase,
                    points[i].errors, points[i].last, result.best_start,
                    result.best_length, result.sample_count) < 0) return -3;
    }
    *baseline += eye_scalar_cycles(count);
    return 0;
}
int main(int argc, char **argv) {
    char path[512];
    FILE *fp;
    uint64_t baseline = 0;
    int n, rc = 0;
    if (argc != 2) { (void)fprintf(stderr, "usage: %s OUTPUT_DIR\n", argv[0]); return 2; }
    n = snprintf(path, sizeof(path), "%s/vectors.txt", argv[1]);
    if (n < 0 || (size_t)n >= sizeof(path)) { (void)fprintf(stderr, "output path too long\n"); return 2; }
    fp = fopen(path, "w");
    if (fp == NULL) { perror(path); return 2; }
    if (fprintf(fp, "# Author: Asresh\n") < 0) rc = 1;
    if (rc == 0 && emit_scan(fp,0,32,4,0,&baseline) != 0) rc = 1;
    if (rc == 0 && emit_scan(fp,1,96,16383,1,&baseline) != 0) rc = 1;
    if (rc == 0 && emit_scan(fp,2,96,32767,1,&baseline) != 0) rc = 1;
    if (rc == 0 && emit_scan(fp,3,96,49151,1,&baseline) != 0) rc = 1;
    if (fclose(fp) != 0) rc = 1;
    if (rc != 0) { (void)fprintf(stderr, "vector generation failed\n"); return 1; }
    (void)printf("generated 320 vectors; scalar baseline cycles=%llu\n", (unsigned long long)baseline);
    return 0;
}
