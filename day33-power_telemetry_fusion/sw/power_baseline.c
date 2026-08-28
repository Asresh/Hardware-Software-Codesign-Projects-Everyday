/* Author: Asresh */
/* Cycle-accounted scalar MCU baseline. The arithmetic result is produced by the
 * independent reference, while the returned count models the unpack/compare/
 * multiply/reduce/store instruction path that hardware replaces. */
#include "power_telemetry.h"

uint64_t ptf_scalar_baseline(const uint32_t *samples, uint32_t *results,
                             size_t count, const struct ptf_config *config)
{
    uint64_t cycles = 18u; /* function setup and descriptor validation */
    size_t index;
    if (samples == NULL || results == NULL || config == NULL)
        return 0u;
    for (index = 0; index < count; ++index) {
        results[index] = ptf_reference(samples[index], config);
        /* load + unpack + compares + three multiplies + stores on a small MCU. */
        cycles += 47u;
    }
    return cycles;
}
