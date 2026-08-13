/* ---------------------------------------------------------------------------
 * scan_baseline.c
 * Software-only scalar prefix sum - the reference point the accelerator is
 * measured against - plus an explicit, conservative cycle model.
 *
 * A scalar prefix sum is a strict data-dependency chain: each element does one
 * load, one add into the running sum, and one store, and the next add cannot
 * start until this add retires. On a single-issue in-order core that is
 * SCAN_CPE = 3 cycles/element (loads/stores overlap the add latency but the
 * carried dependency on the running sum does not). The model deliberately
 * ignores loop overhead, so it under-counts the baseline and never inflates the
 * reported speedup.
 * ------------------------------------------------------------------------- */
#include "scan_accel.h"

void scan_baseline(const uint32_t *in, uint32_t *out, uint32_t len, int exclusive)
{
    uint32_t running = 0u;
    for (uint32_t i = 0; i < len; i++) {
        if (exclusive) { out[i] = running; running += in[i]; }
        else           { running += in[i]; out[i] = running; }
    }
}

uint64_t scan_baseline_cycles(uint32_t len)
{
    return (uint64_t)SCAN_CPE * (uint64_t)len;
}
