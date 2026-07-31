/* ---------------------------------------------------------------------------
 * sfu_baseline.c
 * The software-only baseline the accelerator is measured against: a scalar CPU
 * evaluating the same transcendentals with an independent, hand-written CORDIC
 * loop (separate from the shared sfu_eval, so agreement between the two is a
 * real cross-check). It produces the identical results and returns a dynamic
 * operation count under a simple 1-op-per-cycle RISC model, so the speedup the
 * report quotes is HW cycles (measured in RTL simulation) against SW cycles
 * (this modelled instruction count over the real request workload).
 *
 * Per-iteration budget: 2 arithmetic shifts + 1 direction compare/select
 *   + x update + y update + z update + loop counter compare/branch/increment
 *   ~= 10 scalar ops. Per-op fixed overhead (argument pre-scale: up to two
 *   Q4.28 multiplies + adds, result mapping, dispatch): ~= 24 ops.
 * ------------------------------------------------------------------------- */
#include "sfu_accel.h"

#define OPS_PER_ITER  10u
#define OPS_FIXED     24u

/* one independent CORDIC pass, written out separately from sfu_cordic() */
static void cordic_scalar(int is_hyp, int is_vec,
                          int64_t x0, int64_t y0, int64_t z0,
                          int64_t *xo, int64_t *yo, int64_t *zo)
{
    int64_t x = x0, y = y0, z = z0;
    int n = is_hyp ? (int)SFU_NH : (int)SFU_NC;
    for (int s = 0; s < n; s++) {
        int     shf = is_hyp ? sfu_hyp_shf[s] : s;
        int64_t ang = is_hyp ? sfu_atanh_tab[s] : sfu_atan_tab[s];
        int64_t xr  = x >> shf;
        int64_t yr  = y >> shf;
        if (is_vec ? (y < 0) : (z >= 0)) {
            x = is_hyp ? (x + yr) : (x - yr);
            y = y + xr;
            z = z - ang;
        } else {
            x = is_hyp ? (x - yr) : (x + yr);
            y = y - xr;
            z = z + ang;
        }
    }
    *xo = x; *yo = y; *zo = z;
}

/* per-op iteration count for the cost model */
static unsigned iters_for(uint32_t op)
{
    switch (op) {
        case SFU_OP_SINCOS:
        case SFU_OP_ATAN2:    return SFU_NC;
        default:              return SFU_NH;   /* exp, coshsinh, ln, sqrt */
    }
}

static void eval_scalar(uint32_t op, int32_t a, int32_t b,
                        int32_t *r0, int32_t *r1)
{
    int is_hyp = 0, is_vec = 0;
    int64_t x0 = 0, y0 = 0, z0 = 0, xo, yo, zo;
    switch (op) {
        case SFU_OP_SINCOS:   x0 = sfu_invKc; z0 = a; break;
        case SFU_OP_EXP:
        case SFU_OP_COSHSINH: is_hyp = 1; x0 = sfu_invKh; z0 = a; break;
        case SFU_OP_ATAN2:    is_vec = 1;
                              x0 = sfu_qmul(sfu_invKc, b);
                              y0 = sfu_qmul(sfu_invKc, a); break;
        case SFU_OP_LN:       is_hyp = 1; is_vec = 1;
                              x0 = sfu_qmul(sfu_invKh, (int64_t)a + SFU_ONE_Q);
                              y0 = sfu_qmul(sfu_invKh, (int64_t)a - SFU_ONE_Q); break;
        case SFU_OP_SQRT:     is_hyp = 1; is_vec = 1;
                              x0 = sfu_qmul(sfu_invKh, (int64_t)a + SFU_QUARTER);
                              y0 = sfu_qmul(sfu_invKh, (int64_t)a - SFU_QUARTER); break;
        default:              *r0 = 0; *r1 = 0; return;
    }
    cordic_scalar(is_hyp, is_vec, x0, y0, z0, &xo, &yo, &zo);
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

uint64_t sfu_baseline_ops(const uint32_t *req, uint32_t count, uint32_t *out)
{
    uint64_t ops = 0;
    for (uint32_t k = 0; k < count; k++) {
        uint32_t op = req[k * SFU_ENTRY_WORDS + 0];
        int32_t  a  = (int32_t)req[k * SFU_ENTRY_WORDS + 1];
        int32_t  b  = (int32_t)req[k * SFU_ENTRY_WORDS + 2];
        int32_t  r0, r1;
        eval_scalar(op, a, b, &r0, &r1);
        out[k * 3 + 0] = op;
        out[k * 3 + 1] = (uint32_t)r0;
        out[k * 3 + 2] = (uint32_t)r1;
        ops += (uint64_t)iters_for(op) * OPS_PER_ITER + OPS_FIXED;
    }
    return ops;
}
