/* ----------------------------------------------------------------------------
 * fir_ref.c
 * Golden software model of the FIR computation and the two's-complement
 * formatting helpers shared with the hardware. This is the reference the
 * hardware is diff-tested against, and the baseline the speedup is measured
 * relative to.
 * ------------------------------------------------------------------------- */
#include "fir_accel.h"

/* Streaming FIR, zero initial state, full precision. See header for the exact
 * definition. The inner loop is one multiply-accumulate per tap: taps MACs per
 * output sample, len*taps MACs for the job -- this count is the scalar-CPU
 * baseline the hardware is compared against. */
void fir_ref(const int64_t *h, int taps,
             const int64_t *x, int len,
             int64_t *y)
{
    for (int n = 0; n < len; n++) {
        int64_t acc = 0;
        for (int k = 0; k < taps; k++) {
            int idx = n - k;
            if (idx >= 0)
                acc += h[k] * x[idx];
        }
        y[n] = acc;
    }
}

/* Sign-extend a width-bit two's-complement raw value into int64_t. */
int64_t fir_sign_extend(uint64_t raw, int width)
{
    uint64_t mask = (width >= 64) ? ~0ull : ((1ull << width) - 1u);
    raw &= mask;
    uint64_t sign = 1ull << (width - 1);
    if (raw & sign)
        return (int64_t)(raw | ~mask);   /* set the high bits */
    return (int64_t)raw;
}

/* Reduce a signed value to its width-bit two's-complement bit pattern. */
uint64_t fir_mask_bits(int64_t v, int width)
{
    uint64_t mask = (width >= 64) ? ~0ull : ((1ull << width) - 1u);
    return (uint64_t)v & mask;
}
