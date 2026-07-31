/* ---------------------------------------------------------------------------
 * philox_baseline.c
 * The software-only baseline the accelerator is measured against: a scalar CPU
 * generating the same Philox-4x32-10 stream, one draw at a time, with the 10
 * rounds written out explicitly (independent of the looped golden model, so
 * agreement between the two is a real cross-check). It produces the identical
 * stream and returns a dynamic operation count under a simple 1-op-per-cycle
 * RISC model, so the speedup the report quotes is HW cycles (measured in RTL
 * simulation) against SW cycles (this modelled instruction count over the real
 * draw workload).
 *
 * Per-round budget (with a hardware 32x32->64 multiplier available to the CPU):
 *   2 mulhilo (2 mul + 2 shift + 2 mask = 6) + 4 xor (n0,n2 each 2) + 2 key adds
 *   = 12 ops. Round 0 skips the 2 key adds, so 10 rounds cost 10*12 - 2 = 118.
 * Per-draw fixed overhead: 128-bit counter add (4 adc) + 4 stores + loop/index
 *   compare-branch-increment (4) = 12 ops.
 * ------------------------------------------------------------------------- */
#include "philox_accel.h"

#define OPS_PER_ROUND    12u   /* 2 mulhilo (6) + 4 xor + 2 key add          */
#define OPS_ROUND0_SAVE   2u   /* round 0 does not bump the key              */
#define OPS_FIXED_DRAW   12u   /* counter add + 4 stores + loop overhead     */

/* one Philox-4x32-10 block, rounds fully unrolled by hand */
static void philox10_scalar(const uint32_t ctr_in[4], const uint32_t key_in[2],
                            uint32_t out[4])
{
    uint32_t c0 = ctr_in[0], c1 = ctr_in[1], c2 = ctr_in[2], c3 = ctr_in[3];
    uint32_t k0 = key_in[0], k1 = key_in[1];
    for (uint32_t r = 0; r < PHX_ROUNDS; r++) {
        if (r) { k0 += PHX_W0; k1 += PHX_W1; }
        uint64_t p0 = (uint64_t)PHX_M0 * c0;
        uint64_t p1 = (uint64_t)PHX_M1 * c2;
        uint32_t hi0 = (uint32_t)(p0 >> 32), lo0 = (uint32_t)p0;
        uint32_t hi1 = (uint32_t)(p1 >> 32), lo1 = (uint32_t)p1;
        uint32_t n0 = hi1 ^ c1 ^ k0;
        uint32_t n2 = hi0 ^ c3 ^ k1;
        c0 = n0; c1 = lo1; c2 = n2; c3 = lo0;
    }
    out[0] = c0; out[1] = c1; out[2] = c2; out[3] = c3;
}

uint64_t phx_baseline_ops(const phx_job_t *job, uint32_t *dst)
{
    const uint64_t ops_per_draw =
        (uint64_t)PHX_ROUNDS * OPS_PER_ROUND - OPS_ROUND0_SAVE + OPS_FIXED_DRAW;
    uint64_t ops = 0;
    uint32_t ctr[4], out[4];
    for (uint32_t d = 0; d < job->ndraws; d++) {
        phx_ctr_add(job->ctr, d, ctr);
        philox10_scalar(ctr, job->key, out);
        dst[d * PHX_WORDS_PER_DRAW + 0] = out[0];
        dst[d * PHX_WORDS_PER_DRAW + 1] = out[1];
        dst[d * PHX_WORDS_PER_DRAW + 2] = out[2];
        dst[d * PHX_WORDS_PER_DRAW + 3] = out[3];
        ops += ops_per_draw;
    }
    return ops;
}
