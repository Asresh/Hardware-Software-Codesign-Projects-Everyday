/* ---------------------------------------------------------------------------
 * scan_ref.c
 * Software golden model: an exact prefix sum with the same 32-bit modular
 * wraparound the hardware datapath uses. Every checked output word must match
 * this bit-for-bit.
 * ------------------------------------------------------------------------- */
#include "scan_accel.h"

void scan_reference(const uint32_t *in, uint32_t *out, uint32_t len, int exclusive)
{
    uint32_t running = 0u;   /* 32-bit modular accumulator, matches RTL */
    for (uint32_t i = 0; i < len; i++) {
        if (exclusive) {
            out[i]  = running;      /* sum of strictly-earlier elements */
            running += in[i];
        } else {
            running += in[i];
            out[i]  = running;      /* sum including this element */
        }
    }
}
