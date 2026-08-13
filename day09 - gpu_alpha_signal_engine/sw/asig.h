/* ==========================================================================
 * asig.h - shared contract for the GPU/FPGA alpha-signal engine (day 9).
 *
 * Fixed-point convention (single source of truth for RTL, golden and TB):
 *   - price and all EWMA / momentum / std / z quantities are Q16.16 signed.
 *   - decay weights ALPHA/BETA/GAMMA are Q0.16 unsigned fractions (0..65536).
 *   - every arithmetic op below is defined on two's-complement integers so the
 *     C reference and the Verilog datapath are BIT-EXACT, not merely close.
 *
 * The engine keeps per-symbol streaming state (fast EWMA, slow EWMA, EWMA of
 * squared deviation = variance, tick count) and, per tick, emits an 8-word
 * signal record: {symbol, price, ewma_fast, ewma_slow, std, z, momentum, flags}.
 * ========================================================================== */
#ifndef ASIG_H
#define ASIG_H

#include <stdint.h>

/* ---- design parameters (overridable from the Makefile) ---- */
#ifndef N_SYM
#define N_SYM     64          /* number of tracked instruments            */
#endif
#ifndef SYMW
#define SYMW      6           /* ceil(log2(N_SYM))                        */
#endif
#ifndef FRAC
#define FRAC      16          /* fixed-point fraction bits (Q16.16)       */
#endif

#define REC_WORDS 8           /* 32-bit words per emitted signal record   */

/* record word indices */
enum {
    W_SYM = 0, W_PRICE, W_EWMA_F, W_EWMA_S, W_STD, W_Z, W_MOM, W_FLAGS
};

/* flag bits (record word 7) */
#define F_ALERT   (1u << 0)   /* |z| >= ZTHRESH and warmup complete       */
#define F_ZPOS    (1u << 1)
#define F_ZNEG    (1u << 2)
#define F_MOMUP   (1u << 3)   /* fast EWMA above slow EWMA                 */
#define F_MOMDN   (1u << 4)
#define F_WARM    (1u << 5)   /* count >= WARMUP                          */

/* z saturates to signed 32-bit so a near-zero variance cannot overflow the
 * emitted word; the hardware saturates identically. */
#define Z_SAT_MAX  ((int32_t)0x7FFFFFFF)
#define Z_SAT_MIN  ((int32_t)0x80000000)

/* ---- engine configuration (mirrors the MMIO register file) ---- */
typedef struct {
    int32_t  alpha;      /* Q0.16 fast-EWMA weight    */
    int32_t  beta;       /* Q0.16 slow-EWMA weight    */
    int32_t  gamma;      /* Q0.16 variance weight     */
    int32_t  zthresh;    /* Q16.16 |z| alert level    */
    uint32_t warmup;     /* ticks before signals arm  */
} asig_cfg_t;

/* ---- per-symbol state ---- */
typedef struct {
    int64_t  ewma_fast;  /* Q16.16 */
    int64_t  ewma_slow;  /* Q16.16 */
    int64_t  var;        /* Q16.16 EWMA of squared deviation */
    uint32_t count;
} asig_state_t;

/* one input tick */
typedef struct { uint32_t sym; int32_t price; } asig_tick_t;

/* ---- shared fixed-point kernels (defined in asig_ref.c) ---- */
uint64_t asig_isqrt(uint64_t x);                 /* floor(sqrt(x)), HW-exact */
int32_t  asig_z_from(int64_t dev, int64_t std);  /* saturating Q16.16 z-score */

/* update state with one tick and produce the 8-word record.
 * Returns the record in out[0..REC_WORDS-1]. */
void asig_step(const asig_cfg_t *cfg, asig_state_t *st,
               uint32_t sym, int32_t price, uint32_t out[REC_WORDS]);

#endif /* ASIG_H */
