/* ============================================================================
 * moe.h - shared definitions for the GPU MoE top-k routing / gating engine.
 *
 * One header, three consumers: the reference model (moe_ref.c), the scalar
 * cost-model baseline (moe_baseline.c), the firmware driver (moe_driver.c),
 * and the host/vector generator (moe_host.c).  Every bit of fixed-point math
 * that the RTL must reproduce lives here so the golden model and the hardware
 * are provably the same arithmetic.
 * ==========================================================================*/
#ifndef MOE_H
#define MOE_H

#include <stdint.h>
#include <math.h>

/* ---------------- design parameters (mirror the RTL parameters) ----------- */
#ifndef MOE_E
#define MOE_E 8            /* number of experts                               */
#endif
#ifndef MOE_K
#define MOE_K 2            /* top-k routed experts per token                  */
#endif

#define MOE_LOGIT_W 16     /* signed Q8.8 expert logits                       */
#define MOE_FRAC    16     /* softmax fixed-point fraction bits (Q.16)        */
#define MOE_ONE     (1u << MOE_FRAC)   /* 1.0 in Q.16 == 0x10000              */
#define MOE_EXP_W   18     /* exp value width (holds 0x10000)                 */
#define MOE_WEIGHT_W 18    /* gate weight width (Q.16, up to 0x10000)         */

/* exp look-up table: 257 samples of exp(-i/16) for i in [0,256] in Q.16.
 * abs(d) is clipped at 16.0 (== 4096 in Q8.8); beyond that exp underflows.  */
#define MOE_LUT_N   257
#define MOE_EXP_CLIP_Q88 4096   /* 16.0 in Q8.8                              */

/* ---------------- AXI4-Lite register map ---------------------------------- */
#define REG_CTRL      0x00   /* [0]=enable [1]=soft_reset(W1 pulse) [2]=irq_en */
#define REG_STATUS    0x04   /* [0]=overflow_irq (sticky, W1C)                 */
#define REG_CAP       0x08   /* per-expert capacity (tokens)                   */
#define REG_TOKENS    0x0C   /* total tokens processed (RO)                    */
#define REG_OVERFLOWS 0x10   /* total dropped (over-capacity) slots (RO)       */
#define REG_ROUTED    0x14   /* total accepted routed slots (RO)               */
#define REG_PARAMS    0x18   /* [7:0]=E [15:8]=K [23:16]=LOGIT_W (RO)          */
#define REG_SCRATCH   0x1C   /* RW scratch (bus sanity)                        */
#define REG_EXPLOAD0  0x40   /* per-expert accepted-token counters (RO window) */

#define CTRL_ENABLE   (1u<<0)
#define CTRL_SRESET   (1u<<1)
#define CTRL_IRQEN    (1u<<2)
#define STATUS_OVF_IRQ (1u<<0)

/* ---------------- egress dispatch record (128-bit, K=2 layout) ------------ *
 * lane0 [15:0]  token_id
 * lane1 [17:0]  top0_weight   [25:18] top0_expert   [31] overflow0
 * lane2 [17:0]  top1_weight   [25:18] top1_expert   [31] overflow1
 * lane3 [7:0]   routed_slots (accepted this token)                          */
typedef struct {
    uint16_t token_id;
    uint8_t  expert[MOE_K];
    uint32_t weight[MOE_K];   /* Q.16 */
    uint8_t  overflow[MOE_K];
    uint8_t  routed;          /* number of accepted (non-dropped) slots      */
} moe_record_t;

/* router state carried across tokens (per-expert load + running stats)      */
typedef struct {
    uint32_t load[MOE_E];     /* accepted tokens per expert                   */
    uint32_t cap;             /* capacity per expert                          */
    uint64_t tokens;
    uint64_t routed;
    uint64_t overflows;
} moe_state_t;

/* ---------------- shared fixed-point kernels (bit-exact vs RTL) ----------- */

/* Build the exp LUT.  Identical formula the host writes to exp_lut.hex and
 * the RTL loads via $readmemh, guaranteeing hardware == software.           */
static inline void moe_build_lut(uint32_t lut[MOE_LUT_N]) {
    int i;
    for (i = 0; i < MOE_LUT_N; i++) {
        double e = exp(-(double)i / 16.0);        /* arg 0..-16               */
        long v = lround(e * 65536.0);             /* Q.16                     */
        if (v > (long)MOE_ONE) v = MOE_ONE;        /* i==0 -> exp(0)=1.0       */
        if (v < 0) v = 0;
        lut[i] = (uint32_t)v;
    }
}

/* exp(d) in Q.16 for d<=0 (Q8.8 signed), piecewise-linear interpolation.
 * Pure integer arithmetic; the RTL performs the identical operations.       */
static inline uint32_t moe_exp_q16(int32_t d, const uint32_t lut[MOE_LUT_N]) {
    int32_t a = -d;                    /* d<=0 -> a>=0 (Q8.8)                 */
    if (a < 0) a = 0;
    if (a >= MOE_EXP_CLIP_Q88) return 0;
    int idx  = a >> 4;                 /* 0..255                              */
    int frac = a & 15;
    uint32_t base = lut[idx];
    uint32_t nxt  = lut[idx + 1];
    uint32_t delta = base - nxt;       /* >=0, monotone decreasing           */
    return base - ((delta * (uint32_t)frac) >> 4);
}

/* floor(exp * 2^16 / den) : the same integer division the RTL divider does. */
static inline uint32_t moe_gate_q16(uint32_t expv, uint32_t den) {
    if (den == 0) return 0;
    return (uint32_t)(((uint64_t)expv << MOE_FRAC) / den);
}

/* ---------------- reference + baseline entry points ----------------------- */
/* moe_ref.c : bit-exact golden router (updates state, fills rec).           */
void moe_route(moe_state_t *st, const int16_t logit[MOE_E],
               uint16_t token_id, const uint32_t lut[MOE_LUT_N],
               moe_record_t *rec);

/* moe_baseline.c : documented scalar CPU cost model (cycles for one token). */
long moe_baseline_cycles_per_token(void);

#endif /* MOE_H */
