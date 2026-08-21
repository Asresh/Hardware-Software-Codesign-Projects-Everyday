/* Author: Asresh */
#include "eye_margin.h"
int eye_reference(const struct eye_point *points, size_t count, uint16_t limit, struct eye_result *out) {
    size_t i;
    uint16_t run = 0, best = 0;
    uint8_t run_start = 0, best_start = 0;
    if (points == NULL || out == NULL || count == 0 || count > EYE_MAX_POINTS) return -1;
    for (i = 0; i < count; ++i) {
        if (points[i].phase >= EYE_MAX_POINTS || points[i].last != (uint8_t)(i + 1u == count)) return -2;
        if (points[i].errors <= limit) {
            if (run == 0) run_start = points[i].phase;
            ++run;
            if (run > best) { best = run; best_start = run_start; }
        } else run = 0;
    }
    out->best_start = best_start; out->best_length = best; out->sample_count = (uint16_t)count;
    return 0;
}
