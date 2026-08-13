/* ==========================================================================
 * asig_ref.c - software golden model for the alpha-signal engine.
 *
 * Every operation here is the exact integer computation the RTL performs, so
 * the testbench can compare hardware output word-for-word.  The two non-trivial
 * kernels - the digit-by-digit integer square root and the restoring divider -
 * are written the same way the Verilog unrolls them.
 * ========================================================================== */
#include "asig.h"

/* -------- integer square root: floor(sqrt(x)) -----------------------------
 * Digit-by-digit ("Hero"/Dijkstra) sqrt.  The RTL unrolls exactly this loop as
 * 32 pipeline stages with the test bit starting at 1<<62, so we start there too
 * (no leading-zero skip) to stay bit-identical. */
uint64_t asig_isqrt(uint64_t x)
{
    uint64_t res = 0;
    int i;
    for (i = 0; i < 32; i++) {
        uint64_t bit = (uint64_t)1 << (62 - 2 * i);
        if (x >= res + bit) { x -= res + bit; res = (res >> 1) + bit; }
        else                {                 res =  res >> 1;        }
    }
    return res;
}

/* -------- saturating Q16.16 z-score: dev / std ----------------------------
 * dev, std are Q16.16.  z = (dev << 16) / std keeps the result in Q16.16.
 * Sign is handled on magnitudes so truncation is toward zero (matches the
 * unsigned restoring divider in hardware), then the result saturates to
 * signed 32-bit exactly as the datapath does. */
int32_t asig_z_from(int64_t dev, int64_t std)
{
    uint64_t num, q;
    int neg;
    if (std == 0) return 0;                 /* variance not yet established */
    neg = (dev < 0);
    num = (uint64_t)(neg ? -dev : dev) << FRAC;
    q   = num / (uint64_t)std;              /* floor, magnitude only        */
    if (neg) {
        if (q > (uint64_t)0x80000000ULL) return Z_SAT_MIN;
        return -(int32_t)q;
    }
    if (q > (uint64_t)0x7FFFFFFFULL) return Z_SAT_MAX;
    return (int32_t)q;
}

/* -------- one streaming step ---------------------------------------------- */
void asig_step(const asig_cfg_t *cfg, asig_state_t *st,
               uint32_t sym, int32_t price, uint32_t out[REC_WORDS])
{
    int64_t x = (int64_t)price;             /* Q16.16 */
    int64_t dev, std_q, mom;
    int32_t z;
    uint32_t flags = 0;

    if (st->count == 0) {
        /* seed EWMAs with the first observed price (real HFT engines do this
         * to avoid a huge cold-start transient); variance starts at zero. */
        st->ewma_fast = x;
        st->ewma_slow = x;
        st->var       = 0;
        st->count     = 1;
    } else {
        int64_t df = x - st->ewma_fast;
        st->ewma_fast += (df * (int64_t)cfg->alpha) >> FRAC;
        int64_t ds = x - st->ewma_slow;
        st->ewma_slow += (ds * (int64_t)cfg->beta) >> FRAC;
        int64_t d  = x - st->ewma_slow;             /* deviation vs new slow  */
        int64_t d2 = (d * d) >> FRAC;               /* Q16.16 squared dev     */
        st->var += ((d2 - st->var) * (int64_t)cfg->gamma) >> FRAC;
        if (st->count != 0xFFFFFFFFu) st->count++;
    }

    dev   = x - st->ewma_slow;                      /* Q16.16 */
    std_q = (int64_t)asig_isqrt((uint64_t)st->var << FRAC);
    z     = asig_z_from(dev, std_q);
    mom   = st->ewma_fast - st->ewma_slow;

    if (st->count >= cfg->warmup) flags |= F_WARM;
    if (z > 0) flags |= F_ZPOS;
    if (z < 0) flags |= F_ZNEG;
    if (mom > 0) flags |= F_MOMUP;
    if (mom < 0) flags |= F_MOMDN;
    {
        int32_t zabs = (z < 0) ? -z : z;
        if ((flags & F_WARM) && zabs >= cfg->zthresh) flags |= F_ALERT;
    }

    out[W_SYM]    = sym;
    out[W_PRICE]  = (uint32_t)(int32_t)x;
    out[W_EWMA_F] = (uint32_t)(int32_t)st->ewma_fast;
    out[W_EWMA_S] = (uint32_t)(int32_t)st->ewma_slow;
    out[W_STD]    = (uint32_t)(int32_t)std_q;
    out[W_Z]      = (uint32_t)z;
    out[W_MOM]    = (uint32_t)(int32_t)mom;
    out[W_FLAGS]  = flags;
}
