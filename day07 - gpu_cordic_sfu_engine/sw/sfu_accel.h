/* ---------------------------------------------------------------------------
 * sfu_accel.h
 * Register map, ring-buffer descriptor and driver / reference / baseline API for
 * the GPU-style CORDIC Special Function Unit (SFU). Shared by the bare-metal
 * driver, the software golden model, the scalar baseline and the vector
 * generator so the hardware, the firmware and the test vectors can never drift
 * apart: there is exactly one definition of the fixed-point CORDIC iteration and
 * the per-function argument/result mapping, and everyone includes it.
 *
 * A GPU streaming multiprocessor does not spend a general-purpose ALU on
 * sin/cos/exp/log/rsqrt - it dispatches them to a small pool of fixed-function
 * Special Function Units. This engine is that SFU pool: a SIMD array of
 * iterative CORDIC lanes that evaluate a transcendental every ~30 cycles, driven
 * from a shared submission/completion ring buffer in device memory (a GPU
 * pushbuffer / command ring). Every function reduces to one unified CORDIC
 * rotation or vectoring pass in circular or hyperbolic mode - the same silicon
 * shifts-and-adds evaluate all six ops. These kernels are the hot path in HFT
 * option pricing (Black-Scholes needs exp / ln / sqrt, the normal CDF needs
 * more), in DSP mixers (sin/cos), and in geometry (atan2 / hypot).
 *
 * CORDIC (Volder 1959, Walther 1971) computes a rotation as a sequence of
 * shift-and-add micro-rotations by fixed angles atan(2^-i) (circular) or
 * atanh(2^-i) (hyperbolic); no multiplier is needed in the iteration. The gain
 * of the product of the micro-rotations is a known constant K, divided out here
 * by pre-scaling the initial vector.
 * ------------------------------------------------------------------------- */
#ifndef SFU_ACCEL_H
#define SFU_ACCEL_H

#include <stdint.h>
#include <stddef.h>

/* ---- mailbox register byte offsets (must match rtl/sfu_regfile.v) ---- */
#define SFU_REG_IDENT    0x00u   /* RO  engine identity                        */
#define SFU_REG_CTRL     0x04u   /* WO  doorbell / interrupt control           */
#define SFU_REG_STATUS   0x08u   /* RO  done / busy / irq                      */
#define SFU_REG_REQ_BASE 0x0Cu   /* RW  request ring base (32-bit word addr)   */
#define SFU_REG_RES_BASE 0x10u   /* RW  result  ring base (32-bit word addr)   */
#define SFU_REG_RING_CAP 0x14u   /* RW  ring capacity in entries (power of 2)  */
#define SFU_REG_REQ_HEAD 0x18u   /* RW  first request entry index (consumer)   */
#define SFU_REG_RES_HEAD 0x1Cu   /* RW  first result  entry index (producer)   */
#define SFU_REG_COUNT    0x20u   /* RW  number of requests to process          */
#define SFU_REG_CYCLES   0x24u   /* RO  cycles of the last completed job       */
#define SFU_REG_LANES    0x28u   /* RO  SIMD lane count (build parameter)      */

/* ---- CTRL write bits (doorbell) ---- */
#define SFU_CTRL_START   0x1u
#define SFU_CTRL_IRQ_EN  0x2u
#define SFU_CTRL_IRQ_CLR 0x4u

/* ---- STATUS read bits ---- */
#define SFU_STATUS_DONE  0x1u
#define SFU_STATUS_BUSY  0x2u
#define SFU_STATUS_IRQ   0x4u

#define SFU_IDENT_VALUE  0x5C1D0007u   /* 0x5C1D tag, day 7 */

/* ---- ring entry geometry ---- */
/* request entry (4 words): [op, a, b, reserved]
 * result  entry (4 words): [op, r0, r1, reserved] */
#define SFU_ENTRY_WORDS  4u

/* ---- fixed-point format: signed Q4.28 (range +/-8, resolution 2^-28) ---- */
#define SFU_FBITS   28
#define SFU_ONE_Q   (1 << SFU_FBITS)          /* 1.0 in Q4.28                 */
#define SFU_QUARTER (SFU_ONE_Q >> 2)          /* 0.25 in Q4.28                */

/* ---- CORDIC iteration schedule sizes ---- */
#define SFU_NC   28u    /* circular steps: shifts 0 .. 27                     */
#define SFU_NH   29u    /* hyperbolic steps: shifts 1 .. 27, repeats at 4,13  */
#define SFU_NROM (SFU_NC + SFU_NH)

/* ---- function opcodes (must match rtl/sfu_decode.v) ---- */
enum {
    SFU_OP_SINCOS   = 0,   /* a = angle z (rad, |z|<=1.5)   -> r0=sin, r1=cos  */
    SFU_OP_EXP      = 1,   /* a = z (|z|<=1.1)              -> r0=exp, r1=cosh */
    SFU_OP_COSHSINH = 2,   /* a = z (|z|<=1.1)             -> r0=cosh, r1=sinh */
    SFU_OP_ATAN2    = 3,   /* a = y, b = x (x>0)          -> r0=atan2, r1=hypot*/
    SFU_OP_LN       = 4,   /* a = w (0.15<=w<=6)           -> r0=ln(w)         */
    SFU_OP_SQRT     = 5,   /* a = w (0.03<=w<=2.3)         -> r0=sqrt(w)       */
    SFU_OP_COUNT    = 6
};

/* One CORDIC job descriptor, mirrored by the mailbox register block. The engine
 * consumes COUNT requests from the request ring starting at REQ_HEAD (wrapping
 * modulo RING_CAP) and posts COUNT results to the result ring starting at
 * RES_HEAD (also wrapping). */
typedef struct {
    uint32_t req_base;   /* request ring base word address                    */
    uint32_t res_base;   /* result  ring base word address                    */
    uint32_t ring_cap;   /* ring capacity in entries (power of two)           */
    uint32_t req_head;   /* first request entry index                         */
    uint32_t res_head;   /* first result  entry index                         */
    uint32_t count;      /* number of requests to process                     */
} sfu_job_t;

/* ------------------------------------------------------------------------- *
 *  The one true CORDIC primitive - bit-identical to rtl/cordic_core.v.
 *  The angle tables and gains are filled by sfu_init() from libm, then rounded
 *  to Q4.28 integers; sfu_emit_rom() writes those very integers to the Verilog
 *  ROM, so the hardware and this model iterate on the same constants and the
 *  hardware is bit-exact against this golden.
 * ------------------------------------------------------------------------- */

/* CORDIC schedule tables (filled by sfu_init) */
extern int32_t sfu_atan_tab[SFU_NC];      /* atan(2^-i),  i = 0 .. NC-1  Q4.28 */
extern int32_t sfu_hyp_shf[SFU_NH];       /* hyperbolic shift amount per step   */
extern int32_t sfu_atanh_tab[SFU_NH];     /* atanh(2^-shf) per step,     Q4.28  */
extern int32_t sfu_invKc;                 /* 1 / circular gain           Q4.28  */
extern int32_t sfu_invKh;                 /* 1 / hyperbolic gain         Q4.28  */

/* Build the fixed-point schedule. Must be called once before any evaluation. */
void sfu_init(void);

/* Emit the Verilog ROM ($readmemh format) and the params include so the RTL
 * elaborates on exactly these constants. */
int  sfu_emit_rom(const char *rom_path);

/* Unified iterative CORDIC (int64 working regs, arithmetic shifts). is_hyp
 * selects hyperbolic vs circular, is_vec selects vectoring vs rotation. */
static inline void sfu_cordic(int is_hyp, int is_vec,
                              int64_t x0, int64_t y0, int64_t z0,
                              int64_t *xo, int64_t *yo, int64_t *zo)
{
    int64_t x = x0, y = y0, z = z0;
    int n = is_hyp ? (int)SFU_NH : (int)SFU_NC;
    for (int s = 0; s < n; s++) {
        int      shf = is_hyp ? sfu_hyp_shf[s] : s;
        int64_t  ang = is_hyp ? sfu_atanh_tab[s] : sfu_atan_tab[s];
        int      pos = is_vec ? (y < 0) : (z >= 0);   /* micro-rotation dir    */
        int64_t  xs  = x >> shf;                       /* arithmetic (floor)    */
        int64_t  ys  = y >> shf;
        int64_t  xn, yn, zn;
        if (is_hyp) xn = pos ? (x + ys) : (x - ys);
        else        xn = pos ? (x - ys) : (x + ys);
        yn = pos ? (y + xs) : (y - xs);
        zn = pos ? (z - ang) : (z + ang);
        x = xn; y = yn; z = zn;
    }
    *xo = x; *yo = y; *zo = z;
}

/* signed Q4.28 multiply (matches the 64-bit multiply-then-shift in RTL) */
static inline int64_t sfu_qmul(int64_t a, int64_t b)
{
    return (int64_t)(((__int128)a * (__int128)b) >> SFU_FBITS);
}

/* Map one (op,a,b) request to CORDIC inputs, run it, and map the CORDIC outputs
 * to the two result words. Bit-identical to rtl/sfu_decode.v + cordic_core.v. */
static inline void sfu_eval(uint32_t op, int32_t a, int32_t b,
                            int32_t *r0, int32_t *r1)
{
    int is_hyp = 0, is_vec = 0;
    int64_t x0 = 0, y0 = 0, z0 = 0, xo, yo, zo;

    switch (op) {
        case SFU_OP_SINCOS:
            is_hyp = 0; is_vec = 0;
            x0 = sfu_invKc; y0 = 0; z0 = a; break;
        case SFU_OP_EXP:
        case SFU_OP_COSHSINH:
            is_hyp = 1; is_vec = 0;
            x0 = sfu_invKh; y0 = 0; z0 = a; break;
        case SFU_OP_ATAN2:                        /* a = y, b = x */
            is_hyp = 0; is_vec = 1;
            x0 = sfu_qmul(sfu_invKc, b);
            y0 = sfu_qmul(sfu_invKc, a); z0 = 0; break;
        case SFU_OP_LN:                           /* a = w */
            is_hyp = 1; is_vec = 1;
            x0 = sfu_qmul(sfu_invKh, (int64_t)a + SFU_ONE_Q);
            y0 = sfu_qmul(sfu_invKh, (int64_t)a - SFU_ONE_Q); z0 = 0; break;
        case SFU_OP_SQRT:                         /* a = w */
            is_hyp = 1; is_vec = 1;
            x0 = sfu_qmul(sfu_invKh, (int64_t)a + SFU_QUARTER);
            y0 = sfu_qmul(sfu_invKh, (int64_t)a - SFU_QUARTER); z0 = 0; break;
        default:
            *r0 = 0; *r1 = 0; return;
    }

    sfu_cordic(is_hyp, is_vec, x0, y0, z0, &xo, &yo, &zo);

    switch (op) {
        case SFU_OP_SINCOS:   *r0 = (int32_t)yo;        *r1 = (int32_t)xo; break;
        case SFU_OP_EXP:      *r0 = (int32_t)(xo + yo); *r1 = (int32_t)xo; break;
        case SFU_OP_COSHSINH: *r0 = (int32_t)xo;        *r1 = (int32_t)yo; break;
        case SFU_OP_ATAN2:    *r0 = (int32_t)zo;        *r1 = (int32_t)xo; break;
        case SFU_OP_LN:       *r0 = (int32_t)(zo * 2);  *r1 = 0;           break;
        case SFU_OP_SQRT:     *r0 = (int32_t)xo;        *r1 = 0;           break;
        default:              *r0 = 0;                  *r1 = 0;           break;
    }
}

/* golden model: for each request k in [0,count), read (op,a,b) from the request
 * ring and write (op,r0,r1) into out[k*3 .. k*3+2] (sfu_ref.c). The caller lays
 * out req/out in request order; ring wrap is applied by the host/testbench. */
void sfu_reference(const uint32_t *req, uint32_t count, uint32_t *out);

/* scalar baseline: same results, and returns the dynamic scalar op count
 * (1 op / cycle model) for the software-only cost (sfu_baseline.c). */
uint64_t sfu_baseline_ops(const uint32_t *req, uint32_t count, uint32_t *out);

#endif /* SFU_ACCEL_H */
