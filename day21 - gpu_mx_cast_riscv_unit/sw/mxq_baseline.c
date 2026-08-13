/* ===========================================================================
 * mxq_baseline.c - the same cast a third time, and a scalar cost model.
 *
 * Two jobs:
 *
 * 1. An implementation that shares no logic with sw/mxq_model.c.  The model
 *    forms |v|/scale as a Q4.8 fixed-point number and counts midpoint
 *    crossings; this one converts the bf16 to a double, divides by the scale
 *    (exact - the scale is a power of two), and picks the nearest of the eight
 *    E2M1 grid values by absolute distance, breaking an exact tie towards the
 *    even index.  Both are exact, so if either has the rounding rule subtly
 *    wrong the host stops before a single vector is emitted.  The base-RV32I
 *    kernel is a fourth implementation and the RTL functional unit a fifth.
 *
 * 2. The cost of doing this on the host CPU, per element, in the units the
 *    hardware is measured in.  The real baseline this day reports is the
 *    base-ISA kernel running on the same core - measured, not modelled - so
 *    these numbers exist to say what the work costs in the abstract, and the
 *    per-element charges below are the sequence in sw/mxq_kernels.c, counted.
 * ===========================================================================*/
#include <math.h>
#include <stddef.h>
#include "mxq.h"

static const double MXQ_GRID[8] = { 0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0 };

/* exact magnitude of a bf16, with this day's edge rules applied */
static double bf16_mag(uint16_t b)
{
    uint32_t mag = (uint32_t)(b & 0x7FFFu);
    uint32_t e   = mag >> 7;
    uint32_t m;
    if (e == 0xFFu) mag = MXQ_BF16_MAXF, e = mag >> 7;   /* Inf / NaN clamp  */
    if (e == 0u) return 0.0;                             /* subnormal flush  */
    m = mag & 0x7Fu;
    return ldexp(1.0 + (double)m / 128.0, (int)e - 127);
}

uint8_t mxq_quant_elem_fp(uint16_t b, uint8_t scale)
{
    double u = bf16_mag(b) / ldexp(1.0, (int)scale - 127);
    uint32_t s = (uint32_t)(b >> 15) & 1u;
    int best = 0;
    double bd = fabs(u - MXQ_GRID[0]);
    for (int i = 1; i < 8; i++) {
        double d = fabs(u - MXQ_GRID[i]);
        if (d < bd)                        { best = i; bd = d; }
        else if (d == bd && (i & 1) == 0)  { best = i; }   /* tie -> even    */
    }
    if (u > MXQ_GRID[7]) best = 7;         /* saturate above the grid        */
    return (uint8_t)((s << 3) | (uint32_t)best);
}

double mxq_dequant_value(uint8_t code, uint8_t scale)
{
    double v = MXQ_GRID[code & 7u] * ldexp(1.0, (int)scale - 127);
    return (code & 8u) ? -v : v;
}

/* ---- scalar cost model ---------------------------------------------------
 * Charges taken from the emitted base-RV32I sequence: the amax fold is 11
 * instructions per element including the call and the return, the quantise is
 * 46 on the common path, and the block adds the pointer walk, the scale and
 * the packing.  Loads and stores are counted separately because on a real
 * host they are what the cast is bounded by. */
#define C_AMAX_ELEM  11u
#define C_QUANT_ELEM 46u
#define C_BLOCK_FIX  30u
#define C_DEQ_ELEM   26u

void mxq_baseline_quant(const uint16_t *in, int nblk, int blk,
                        uint8_t *scales, uint8_t *codes, mxq_cost_t *cost)
{
    cost->instr = cost->loads = cost->stores = cost->branches = 0;
    for (int b = 0; b < nblk; b++) {
        const uint16_t *v = in + (size_t)b * blk;
        uint8_t x = mxq_shared_scale(mxq_bf16_amax(v, blk));
        scales[b] = x;
        for (int i = 0; i < blk; i += 2) {
            uint8_t lo = mxq_quant_elem(v[i], x);
            uint8_t hi = mxq_quant_elem(v[i + 1], x);
            codes[(size_t)b * (blk / 2) + i / 2] = (uint8_t)((hi << 4) | lo);
        }
        cost->instr   += (uint64_t)blk * (C_AMAX_ELEM + C_QUANT_ELEM)
                       + C_BLOCK_FIX;
        cost->loads   += (uint64_t)blk;               /* two passes, 2/word  */
        cost->stores  += 1u + (uint64_t)blk / 8u;
        cost->branches += (uint64_t)blk * 3u;
    }
}

void mxq_baseline_dequant(const uint8_t *scales, const uint8_t *codes,
                          int nblk, int blk, uint16_t *out, mxq_cost_t *cost)
{
    cost->instr = cost->loads = cost->stores = cost->branches = 0;
    for (int b = 0; b < nblk; b++) {
        mxq_dequant_block(scales[b], codes + (size_t)b * (blk / 2), blk,
                          out + (size_t)b * blk);
        cost->instr    += (uint64_t)blk * C_DEQ_ELEM + C_BLOCK_FIX;
        cost->loads    += 1u + (uint64_t)blk / 8u;
        cost->stores   += (uint64_t)blk / 2u;
        cost->branches += (uint64_t)blk * 2u;
    }
}
