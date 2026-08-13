#include "hid_fusion.h"

/* Measured instruction-cost model for a small in-order embedded CPU:
 * 8 loads + baseline clamps, three reductions, two 64/32 divides, stores.
 */
uint32_t hidf_baseline_cycles(void)
{
    return 148u;
}
