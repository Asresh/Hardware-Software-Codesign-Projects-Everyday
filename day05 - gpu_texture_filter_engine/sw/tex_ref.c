/* ---------------------------------------------------------------------------
 * tex_ref.c
 * The golden model. Resamples a source image with exactly the fixed-point
 * bilinear arithmetic the hardware uses (tex_bilinear() in tex_accel.h), walking
 * output pixels in the same order and using accumulated Q16.16 coordinates. The
 * vector generator calls this to produce the expected image the testbench checks
 * the RTL against, so "reference" and "silicon" are the same equation.
 * ------------------------------------------------------------------------- */
#include "tex_accel.h"

void tex_reference(const uint8_t *src, uint8_t *dst, const tex_job_t *job)
{
    for (uint32_t oy = 0; oy < job->dst_h; oy++) {
        uint32_t uy = oy * job->scale_y;               /* == accumulated step */
        for (uint32_t ox = 0; ox < job->dst_w; ox++) {
            uint32_t ux = ox * job->scale_x;
            dst[oy * job->dst_w + ox] =
                tex_bilinear(src, job->src_w, job->src_h, ux, uy);
        }
    }
}
