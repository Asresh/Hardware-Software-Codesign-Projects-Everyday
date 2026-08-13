/* ---------------------------------------------------------------------------
 * tex_baseline.c
 * The software-only baseline the accelerator is measured against: a scalar CPU
 * doing the same bilinear resample, one output pixel at a time. It produces the
 * identical image (a cross-check on the golden model) and returns a dynamic
 * operation count under a simple 1-op-per-cycle RISC model, so the speedup the
 * report quotes is HW cycles (measured in RTL simulation) against SW cycles
 * (this modelled instruction count over the real pixel workload).
 *
 * The per-pixel and per-row op counts below are the inner-loop instruction
 * budget of a straightforward scalar implementation: multiply-free coordinate
 * stepping is NOT assumed for the CPU (it recomputes ox*scale), four texel loads,
 * three lerp multiplies, and the surrounding clamp/index/store/branch work.
 * ------------------------------------------------------------------------- */
#include "tex_accel.h"

/* per-output-pixel scalar instruction budget:
 *   ux=ox*scale (1 mul) + rx>>16 (1) + fx shift&mask (2)
 *   x0 clamp (2) + x1 add&clamp (3)
 *   4x (addr add + load) (8)
 *   top/bot/num lerp: (256-fx)(1) 2mul 1add + 2mul 1add + (256-fy)(1) 2mul 1add + >>16(1) = 12
 *   store (1) + loop compare/branch/increment (3)                              */
#define OPS_PER_PIXEL 33u
/* per-output-row scalar overhead:
 *   uy=oy*scale (1) + ry>>16 (1) + fy shift&mask (2) + y0 clamp (2)
 *   + y1 add&clamp (3) + base_top=y0*W (1) + base_bot=y1*W (1) + loop (3)       */
#define OPS_PER_ROW   14u

uint64_t tex_baseline_ops(const uint8_t *src, uint8_t *dst, const tex_job_t *job)
{
    uint64_t ops = 0;
    for (uint32_t oy = 0; oy < job->dst_h; oy++) {
        uint32_t uy = oy * job->scale_y;
        ops += OPS_PER_ROW;
        for (uint32_t ox = 0; ox < job->dst_w; ox++) {
            uint32_t ux = ox * job->scale_x;
            dst[oy * job->dst_w + ox] =
                tex_bilinear(src, job->src_w, job->src_h, ux, uy);
            ops += OPS_PER_PIXEL;
        }
    }
    return ops;
}
