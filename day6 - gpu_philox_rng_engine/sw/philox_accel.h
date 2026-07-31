/* ---------------------------------------------------------------------------
 * philox_accel.h
 * Register map, job descriptor and driver / reference / baseline API for the
 * GPU-style Philox-4x32-10 counter-based parallel RNG engine. Shared by the
 * bare-metal driver, the software golden model, the scalar baseline and the
 * vector generator so the hardware, the firmware and the test vectors can never
 * drift apart: there is exactly one definition of the Philox bijection, and
 * everyone includes it.
 *
 * Philox (Salmon, Moraes, Dror & Shaw, "Parallel Random Numbers: As Easy as 1,
 * 2, 3", SC'11 - the Random123 library, and the default generator in NVIDIA
 * cuRAND) is a *counter-based* PRNG: the n-th random draw is a keyed, invertible
 * function of the integer n, with no carried state. That is exactly what makes
 * it the workhorse for GPU / HFT Monte-Carlo - every path and timestep gets an
 * independent, perfectly reproducible stream from its own counter, and the whole
 * thing parallelises with zero coordination. This engine is the fixed-function
 * silicon version of that generator core.
 * ------------------------------------------------------------------------- */
#ifndef PHILOX_ACCEL_H
#define PHILOX_ACCEL_H

#include <stdint.h>
#include <stddef.h>

/* ---- mailbox register byte offsets (must match rtl/philox_regfile.v) ---- */
#define PHX_REG_IDENT   0x00u   /* RO  engine identity                        */
#define PHX_REG_CTRL    0x04u   /* WO  doorbell / interrupt control           */
#define PHX_REG_STATUS  0x08u   /* RO  done / busy / irq                      */
#define PHX_REG_DST     0x0Cu   /* RW  destination base (32-bit word address) */
#define PHX_REG_NDRAWS  0x10u   /* RW  number of draws (4 words / 16 B each)  */
#define PHX_REG_KEY0    0x14u   /* RW  Philox key word 0 (stream/seed low)    */
#define PHX_REG_KEY1    0x18u   /* RW  Philox key word 1 (stream/seed high)   */
#define PHX_REG_CTR0    0x1Cu   /* RW  base counter word 0 (LSW)              */
#define PHX_REG_CTR1    0x20u   /* RW  base counter word 1                    */
#define PHX_REG_CTR2    0x24u   /* RW  base counter word 2                    */
#define PHX_REG_CTR3    0x28u   /* RW  base counter word 3 (MSW)              */
#define PHX_REG_CYCLES  0x2Cu   /* RO  cycles of the last completed job       */
#define PHX_REG_LANES   0x30u   /* RO  SIMD lane count (build parameter)      */

/* ---- CTRL write bits (doorbell) ---- */
#define PHX_CTRL_START   0x1u    /* ring doorbell: launch the programmed job  */
#define PHX_CTRL_IRQ_EN  0x2u    /* enable completion interrupt               */
#define PHX_CTRL_IRQ_CLR 0x4u    /* acknowledge / clear a pending interrupt   */

/* ---- STATUS read bits ---- */
#define PHX_STATUS_DONE  0x1u
#define PHX_STATUS_BUSY  0x2u
#define PHX_STATUS_IRQ   0x4u

#define PHX_IDENT_VALUE  0x5B160006u   /* 0x5B16 tag, day 6 */

/* ---- Philox-4x32-10 constants (Random123 reference values) ---- */
#define PHX_ROUNDS     10u
#define PHX_M0         0xD2511F53u      /* multiplier for counter word 0      */
#define PHX_M1         0xCD9E8D57u      /* multiplier for counter word 2      */
#define PHX_W0         0x9E3779B9u      /* key0 bump: golden ratio            */
#define PHX_W1         0xBB67AE85u      /* key1 bump: sqrt(3)-1               */

/* Each draw emits 4 x 32-bit random words = 16 bytes, little-endian in memory:
 * word j of draw d lands at dst + d*4 + j. */
#define PHX_WORDS_PER_DRAW 4u

/* One job descriptor, mirrored by the mailbox register block. */
typedef struct {
    uint32_t dst;        /* destination base word address                    */
    uint32_t ndraws;     /* number of Philox draws to generate               */
    uint32_t key[2];     /* {k0,k1}: the seed / stream identifier            */
    uint32_t ctr[4];     /* {c0,c1,c2,c3}: base counter (128-bit, c0 = LSW)  */
} phx_job_t;

/* ---- the one true Philox primitive: bit-identical to rtl/philox_round.v ----
 * A single Philox-4x32 round. `ctr`/`out` are {c0,c1,c2,c3}; `key` is {k0,k1}. */
static inline void phx_round(const uint32_t ctr[4], const uint32_t key[2],
                             uint32_t out[4])
{
    uint64_t p0 = (uint64_t)PHX_M0 * ctr[0];
    uint64_t p1 = (uint64_t)PHX_M1 * ctr[2];
    uint32_t hi0 = (uint32_t)(p0 >> 32), lo0 = (uint32_t)p0;
    uint32_t hi1 = (uint32_t)(p1 >> 32), lo1 = (uint32_t)p1;
    out[0] = hi1 ^ ctr[1] ^ key[0];
    out[1] = lo1;
    out[2] = hi0 ^ ctr[3] ^ key[1];
    out[3] = lo0;
}

/* Full Philox-4x32-10 bijection: 10 rounds, key bumped before rounds 1..9.
 * `ctr_in` is the 128-bit counter for one draw; writes 4 random words to out. */
static inline void phx_block(const uint32_t ctr_in[4], const uint32_t key_in[2],
                             uint32_t out[4])
{
    uint32_t c[4] = { ctr_in[0], ctr_in[1], ctr_in[2], ctr_in[3] };
    uint32_t k[2] = { key_in[0], key_in[1] };
    uint32_t t[4];
    for (uint32_t r = 0; r < PHX_ROUNDS; r++) {
        if (r > 0) { k[0] += PHX_W0; k[1] += PHX_W1; }   /* bump before r>=1 */
        phx_round(c, k, t);
        c[0] = t[0]; c[1] = t[1]; c[2] = t[2]; c[3] = t[3];
    }
    out[0] = c[0]; out[1] = c[1]; out[2] = c[2]; out[3] = c[3];
}

/* Add a small non-negative offset to a 128-bit counter (c0 = LSW), with carry
 * rippling c0 -> c1 -> c2 -> c3. This is how consecutive draws advance: draw d
 * uses counter base + d. Bit-identical to the carry chain in rtl. */
static inline void phx_ctr_add(const uint32_t base[4], uint32_t off,
                               uint32_t out[4])
{
    uint64_t s0 = (uint64_t)base[0] + off;
    uint64_t s1 = (uint64_t)base[1] + (uint32_t)(s0 >> 32);
    uint64_t s2 = (uint64_t)base[2] + (uint32_t)(s1 >> 32);
    uint64_t s3 = (uint64_t)base[3] + (uint32_t)(s2 >> 32);
    out[0] = (uint32_t)s0; out[1] = (uint32_t)s1;
    out[2] = (uint32_t)s2; out[3] = (uint32_t)s3;
}

/* golden model: fill dst[0 .. 4*ndraws-1] with the draw stream (philox_ref.c) */
void phx_reference(const phx_job_t *job, uint32_t *dst);

/* scalar baseline: same stream, and returns the dynamic scalar op count
 * (1 op / cycle model) for the software-only cost (philox_baseline.c) */
uint64_t phx_baseline_ops(const phx_job_t *job, uint32_t *dst);

#endif /* PHILOX_ACCEL_H */
