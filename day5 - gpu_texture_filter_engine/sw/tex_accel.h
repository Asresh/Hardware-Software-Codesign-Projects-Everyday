/* ---------------------------------------------------------------------------
 * tex_accel.h
 * Register map, job descriptor and driver / reference / baseline API for the
 * GPU-style bilinear texture-filter (image resampler) engine. Shared by the
 * bare-metal driver, the software golden model, the scalar baseline and the
 * vector generator so the hardware, the firmware and the test vectors can never
 * drift apart: there is exactly one definition of the fixed-point bilinear
 * arithmetic, and everyone includes it.
 * ------------------------------------------------------------------------- */
#ifndef TEX_ACCEL_H
#define TEX_ACCEL_H

#include <stdint.h>
#include <stddef.h>

/* ---- mailbox register byte offsets (must match rtl/tex_regfile.v) ---- */
#define TEX_REG_IDENT    0x00u   /* RO  engine identity                     */
#define TEX_REG_CTRL     0x04u   /* WO  doorbell / interrupt control        */
#define TEX_REG_STATUS   0x08u   /* RO  done / busy / irq                   */
#define TEX_REG_SRC      0x0Cu   /* RW  source base   (word address)        */
#define TEX_REG_DST      0x10u   /* RW  dest base     (word address)        */
#define TEX_REG_SRC_W    0x14u   /* RW  source width  (pixels, mult of 4)   */
#define TEX_REG_SRC_H    0x18u   /* RW  source height (pixels)              */
#define TEX_REG_DST_W    0x1Cu   /* RW  dest width    (pixels, mult of 4)   */
#define TEX_REG_DST_H    0x20u   /* RW  dest height   (pixels)              */
#define TEX_REG_SCALE_X  0x24u   /* RW  Q16.16 src-pixels per dst-pixel (x) */
#define TEX_REG_SCALE_Y  0x28u   /* RW  Q16.16 src-pixels per dst-pixel (y) */
#define TEX_REG_CYCLES   0x2Cu   /* RO  cycles of the last completed job    */

/* ---- CTRL write bits (doorbell) ---- */
#define TEX_CTRL_START    0x1u   /* ring doorbell: launch the programmed job */
#define TEX_CTRL_IRQ_EN   0x2u   /* enable completion interrupt              */
#define TEX_CTRL_IRQ_CLR  0x4u   /* acknowledge / clear a pending interrupt  */

/* ---- STATUS read bits ---- */
#define TEX_STATUS_DONE   0x1u
#define TEX_STATUS_BUSY   0x2u
#define TEX_STATUS_IRQ    0x4u

#define TEX_IDENT_VALUE   0x5B170005u   /* 0x5B17 tag, day 5 */

/* Pixels are 8-bit grayscale; the memory word packs PPW = 4 pixels, pixel p in
 * byte lane p (little-endian). Widths are constrained to a multiple of 4 so a
 * source/dest row is a whole number of words. */
#define TEX_PIX_W   8
#define TEX_PPW     4

/* Fixed-point: coordinates are Q16.16; the fractional blend weight is the top 8
 * bits of the 16-bit fraction (0..255, where a full weight is 256). */
#define TEX_FRAC_BITS 16
#define TEX_WEIGHT    256

/* One job descriptor, mirrored by the mailbox register block. */
typedef struct {
    uint32_t src;       /* source base word address                 */
    uint32_t dst;       /* dest base word address                   */
    uint32_t src_w;     /* source width  (pixels, multiple of 4)    */
    uint32_t src_h;     /* source height (pixels)                   */
    uint32_t dst_w;     /* dest width    (pixels, multiple of 4)    */
    uint32_t dst_h;     /* dest height   (pixels)                   */
    uint32_t scale_x;   /* Q16.16 step in x                         */
    uint32_t scale_y;   /* Q16.16 step in y                         */
} tex_job_t;

/* Compute the Q16.16 resample step (src pixels per dst pixel). The host does the
 * divide so the hardware never needs a divider - a deliberate co-design split. */
static inline uint32_t tex_scale(uint32_t src_dim, uint32_t dst_dim)
{
    if (dst_dim == 0) return 0;
    return (uint32_t)(((uint64_t)src_dim << TEX_FRAC_BITS) / dst_dim);
}

/* The one true bilinear sample: integer-only, bit-identical to rtl/bilinear_blend.v
 * and rtl/coord_gen.v. `src` is a row-major 8-bit image of src_w x src_h. */
static inline uint8_t tex_bilinear(const uint8_t *src, uint32_t src_w,
                                   uint32_t src_h, uint32_t ux, uint32_t uy)
{
    uint32_t rx = ux >> TEX_FRAC_BITS;
    uint32_t ry = uy >> TEX_FRAC_BITS;
    uint32_t fx = (ux >> (TEX_FRAC_BITS - 8)) & 0xFFu;   /* 0..255 */
    uint32_t fy = (uy >> (TEX_FRAC_BITS - 8)) & 0xFFu;

    uint32_t x0 = (rx > src_w - 1) ? (src_w - 1) : rx;
    uint32_t y0 = (ry > src_h - 1) ? (src_h - 1) : ry;
    uint32_t x1 = (x0 + 1 > src_w - 1) ? (src_w - 1) : x0 + 1;
    uint32_t y1 = (y0 + 1 > src_h - 1) ? (src_h - 1) : y0 + 1;

    uint32_t p00 = src[y0 * src_w + x0];
    uint32_t p01 = src[y0 * src_w + x1];
    uint32_t p10 = src[y1 * src_w + x0];
    uint32_t p11 = src[y1 * src_w + x1];

    uint32_t top = p00 * (TEX_WEIGHT - fx) + p01 * fx;   /* <= 255*256 */
    uint32_t bot = p10 * (TEX_WEIGHT - fx) + p11 * fx;
    uint32_t out = (top * (TEX_WEIGHT - fy) + bot * fy) >> (2 * 8);
    return (uint8_t)out;
}

/* golden model: resample the whole image (tex_ref.c) */
void tex_reference(const uint8_t *src, uint8_t *dst, const tex_job_t *job);

/* scalar baseline: same result, and returns the dynamic scalar op count
 * (1 op / cycle model) for the software-only cost (tex_baseline.c) */
uint64_t tex_baseline_ops(const uint8_t *src, uint8_t *dst, const tex_job_t *job);

#endif /* TEX_ACCEL_H */
