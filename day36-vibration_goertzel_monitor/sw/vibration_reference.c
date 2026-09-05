/* Author: Asresh */
#include "vibration_monitor.h"
void vm_reference(const int16_t *samples, size_t count, const int16_t coeff[4], struct vm_result *out) {
    uint64_t best = 0;
    uint8_t best_bin = 0;
    for (unsigned b = 0; b < 4; ++b) {
        int64_t s1 = 0, s2 = 0;
        for (size_t n = 0; n < count; ++n) {
            int64_t next = samples[n] + (((int64_t)coeff[b] * s1) >> 8) - s2;
            s2 = s1;
            s1 = next;
        }
        int64_t signed_power = s1*s1 + s2*s2 - (((int64_t)coeff[b]*s1*s2) >> 8);
        uint64_t power = (uint64_t)signed_power;
        if (b == 0 || power > best) { best = power; best_bin = (uint8_t)b; }
    }
    out->bin = best_bin;
    out->power = best;
}
