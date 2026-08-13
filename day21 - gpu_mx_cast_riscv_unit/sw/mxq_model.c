/* ===========================================================================
 * mxq_model.c - the MX (microscaling) cast, written once, in plain C.
 *
 * This file is the definition of correctness for the whole day.  The custom
 * functional unit in rtl/mxq_mx_unit.v, the instruction-set simulator and the
 * base-RV32I kernel are three independent implementations of exactly these
 * five functions, and the testbench requires all of them to agree bit for bit.
 *
 * Format (OCP Microscaling, MXFP4): a block of MXQ_BLK bf16 values is replaced
 * by one shared 8-bit power-of-two scale (E8M0, value 2^(X-127)) and one 4-bit
 * E2M1 code per element.  The E2M1 magnitudes are {0, .5, 1, 1.5, 2, 3, 4, 6}
 * and bit 3 is the sign, so the whole block costs 4.25 bits per element
 * instead of 16 - the compression that makes a weight or an activation shard
 * worth moving between devices at all.
 *
 * Three semantic choices are made here rather than left to the caller, because
 * a cast that behaves differently at the edges is a cast that produces
 * different numbers on different hardware:
 *   - bf16 subnormals are flushed to zero (they are below any representable
 *     product of a scale and a code anyway);
 *   - non-finite inputs clamp to the largest finite bf16 magnitude, so one Inf
 *     in a tensor rescales the block instead of destroying it;
 *   - rounding is round-to-nearest-even on the *code index*, which is what
 *     makes the cast unbiased over a block.
 * ===========================================================================*/
#include "mxq.h"

/* midpoints of the E2M1 grid in Q4.8 (units of 1/256):
 *   .25  .75  1.25  1.75  2.5  3.5  5.0                                     */
const uint16_t MXQ_THRESH[MXQ_NTHRESH] = { 64, 192, 320, 448, 640, 896, 1280 };
/* on an exact tie, the even code of the straddling pair                     */
const uint8_t  MXQ_RNE_EVEN[MXQ_NTHRESH] = { 0, 2, 2, 4, 4, 6, 6 };

static const int8_t  MXQ_EOFF[8] = { 0, -1, 0, 0, 1, 1, 2, 2 };
static const uint8_t MXQ_EMAN[8] = { 0, 0, 0, 0x40, 0, 0x40, 0, 0x40 };

/* magnitude of one bf16 as the amax reduction sees it */
static uint16_t amax_mag_of(uint16_t b)
{
    uint16_t m = (uint16_t)(b & 0x7FFFu);
    uint32_t e = (uint32_t)(m >> 7);
    if (e == 0xFFu) return (uint16_t)MXQ_BF16_MAXF;  /* Inf / NaN -> maxfinite */
    if (e == 0u)    return 0;                        /* zero / subnormal       */
    return m;
}

uint16_t mxq_bf16_amax(const uint16_t *v, int n)
{
    uint16_t acc = 0;
    for (int i = 0; i < n; i++) {
        uint16_t m = amax_mag_of(v[i]);
        if (m > acc) acc = m;
    }
    return acc;
}

/* E8M0 shared scale for a block whose amax magnitude field is amax_mag.
 * The scale is chosen so the largest element lands in the top binade of the
 * element format: X = exp(amax) - EMAX_ELEM. */
uint8_t mxq_shared_scale(uint16_t amax_mag)
{
    uint32_t ea = (uint32_t)((amax_mag & 0x7FFFu) >> 7);
    int32_t  x;
    if (ea == 0u)    return 0;            /* all-zero block                   */
    if (ea == 0xFFu) ea = 0xFEu;          /* defensive: caller already clamped */
    x = (int32_t)ea - MXQ_EMAX_ELEM;
    if (x < 0)   x = 0;                   /* scale floor: 2^-127              */
    if (x > 254) x = 254;                 /* 255 is NaN in E8M0               */
    return (uint8_t)x;
}

/* Quantise one bf16 at shared scale X to an E2M1 code.
 *
 * u = |v| / 2^(X-127) is formed as a Q4.8 fixed-point number: the significand
 * 1.mmmmmmm is an 8-bit integer (128+mant) and the whole division is the
 * single shift sh = exp(v) - X + 1.  Everything shifted out of the bottom is
 * OR-ed into a sticky bit, which is the only reason round-to-nearest-*even*
 * can be exact here: without it a value just above a midpoint is
 * indistinguishable from the midpoint itself. */
uint8_t mxq_quant_elem(uint16_t b, uint8_t scale)
{
    uint32_t s    = (uint32_t)(b >> 15) & 1u;
    uint32_t mag  = (uint32_t)(b & 0x7FFFu);
    uint32_t ev   = mag >> 7;
    uint32_t mant = mag & 0x7Fu;
    uint32_t sig, u, us, sticky, c;
    int32_t  sh;

    if (ev == 0xFFu) { ev = MXQ_BF16_MAXF >> 7; mant = MXQ_BF16_MAXF & 0x7Fu; }
    if (ev == 0u) return (uint8_t)(s << 3);      /* zero / subnormal, signed  */

    sig = 128u + mant;
    sh  = (int32_t)ev - (int32_t)scale + 1;

    if (sh > 4) {                 /* only reachable with a mismatched scale   */
        u = 4095u; sticky = 0u;
    } else if (sh >= 0) {
        u = sig << sh; sticky = 0u;
    } else {
        uint32_t n = (uint32_t)(-sh);
        if (n >= 32u) { u = 0u; sticky = 1u; }
        else { u = sig >> n; sticky = (sig & ((1u << n) - 1u)) != 0u; }
    }

    /* The code index is the number of midpoints the value is above.  The
     * pair straddling MXQ_THRESH[k] is (k, k+1), so the even member of that
     * pair is k when k is even and k+1 when it is odd - which turns
     * round-to-nearest-even into one comparison per midpoint with no tie
     * arithmetic at all: an even midpoint compares u+sticky strictly, an odd
     * one compares u inclusively.  MXQ_RNE_EVEN is the table this replaces;
     * mxq_host.c checks the two against each other exhaustively. */
    us = u + sticky;
    c  = 0u;
    for (int k = 0; k < MXQ_NTHRESH; k++)
        c += (k & 1) ? (u >= MXQ_THRESH[k]) : (us > MXQ_THRESH[k]);

    return (uint8_t)((s << 3) | c);
}

/* Reconstruct a bf16 from an E2M1 code and the shared scale.  Exact: every
 * code magnitude is a two-term binary value, so the product with a power of
 * two is a bf16 unless the exponent runs off the end. */
uint16_t mxq_dequant_elem(uint8_t code, uint8_t scale)
{
    uint32_t s = (uint32_t)(code >> 3) & 1u;
    uint32_t c = (uint32_t)(code & 7u);
    int32_t  e;
    if (c == 0u) return (uint16_t)(s << 15);
    e = (int32_t)scale + MXQ_EOFF[c];
    if (e <= 0)   return (uint16_t)(s << 15);                       /* flush  */
    if (e >= 255) return (uint16_t)((s << 15) | MXQ_BF16_MAXF);     /* clamp  */
    return (uint16_t)((s << 15) | ((uint32_t)e << 7) | MXQ_EMAN[c]);
}

void mxq_quant_block(const uint16_t *in, int n, uint8_t *scale, uint8_t *codes)
{
    uint8_t x = mxq_shared_scale(mxq_bf16_amax(in, n));
    *scale = x;
    for (int i = 0; i < n; i += 2) {
        uint8_t lo = mxq_quant_elem(in[i], x);
        uint8_t hi = mxq_quant_elem(in[i + 1], x);
        codes[i >> 1] = (uint8_t)((hi << 4) | lo);
    }
}

void mxq_dequant_block(uint8_t scale, const uint8_t *codes, int n, uint16_t *out)
{
    for (int i = 0; i < n; i += 2) {
        uint8_t byte = codes[i >> 1];
        out[i]     = mxq_dequant_elem((uint8_t)(byte & 0xFu), scale);
        out[i + 1] = mxq_dequant_elem((uint8_t)(byte >> 4), scale);
    }
}

/* Fold of the register map.  The same fold is written out as a localparam in
 * rtl/mxq_defs.vh and read back from MXQ_REG_REGMAP_CSUM in simulation, so a
 * register that moves in one file and not the other fails the run. */
uint32_t mxq_regmap_csum(void)
{
    static const uint32_t off[MXQ_NREGS] = {
        MXQ_REG_CTRL, MXQ_REG_STATUS, MXQ_REG_IRQ_STAT, MXQ_REG_ERRCODE,
        MXQ_REG_START_PC, MXQ_REG_WDOG, MXQ_REG_CYCLES, MXQ_REG_INSTRET,
        MXQ_REG_CUSTOM_OPS, MXQ_REG_BRANCH_TAKEN, MXQ_REG_LOADS,
        MXQ_REG_STORES, MXQ_REG_TRAP_PC, MXQ_REG_ARG0, MXQ_REG_ARG1,
        MXQ_REG_ARG2, MXQ_REG_ARG3, MXQ_REG_RETVAL, MXQ_REG_HALT_PC,
        MXQ_REG_CAPS, MXQ_REG_VERSION, MXQ_REG_REGMAP_CSUM
    };
    uint32_t c = 0;
    for (uint32_t i = 0; i < MXQ_NREGS; i++)
        c += (off[i] + 1u) * (i + 1u);
    c += ((uint32_t)MXQ_NREGS << 12) + MXQ_NCUSTOM;
    return c & 0xFFFFFFFFu;
}
