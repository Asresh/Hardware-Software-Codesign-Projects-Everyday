/* ---------------------------------------------------------------------------
 * philox_ref.c
 * The software golden model. Produces the exact random-word stream the hardware
 * must reproduce: for draw d = 0 .. ndraws-1, the Philox-4x32-10 block of
 * (base_counter + d) under the job key, written as 4 little-endian words at
 * dst + d*4. Built directly on the shared phx_block / phx_ctr_add primitives in
 * philox_accel.h, so it is the reference every other implementation is measured
 * against.
 * ------------------------------------------------------------------------- */
#include "philox_accel.h"

void phx_reference(const phx_job_t *job, uint32_t *dst)
{
    uint32_t ctr[4], out[4];
    for (uint32_t d = 0; d < job->ndraws; d++) {
        phx_ctr_add(job->ctr, d, ctr);          /* counter for this draw     */
        phx_block(ctr, job->key, out);          /* the keyed bijection       */
        dst[d * PHX_WORDS_PER_DRAW + 0] = out[0];
        dst[d * PHX_WORDS_PER_DRAW + 1] = out[1];
        dst[d * PHX_WORDS_PER_DRAW + 2] = out[2];
        dst[d * PHX_WORDS_PER_DRAW + 3] = out[3];
    }
}
