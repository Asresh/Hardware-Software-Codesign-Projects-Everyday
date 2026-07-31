/* ---------------------------------------------------------------------------
 * tex_host.c
 * Host / vector generator. Builds the differential test suite the SystemVerilog
 * testbench replays against the RTL:
 *
 *   - random resample jobs (varied source/dest geometry: magnify, minify and
 *     anisotropic scales) plus hand-picked corner cases (1:1 identity copy,
 *     extreme up/down scale, a height-1 source that exercises vertical
 *     clamp-to-edge, and tall/wide anisotropic images);
 *   - one source image and one golden output image per job (hex, one 32-bit
 *     word = 4 packed pixels per line);
 *   - jobs.txt manifest (addresses, geometry, Q16.16 scales, word counts);
 *   - params.vh so the DUT elaborates at exactly the vectors' geometry;
 *   - sw_metrics.txt carrying the scalar-baseline cost model for the report.
 *
 * tex_reference() produces the golden data; tex_baseline_ops() supplies the
 * software cost and is cross-checked to produce a byte-identical image.
 * ------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tex_accel.h"

/* deterministic, platform-independent PRNG so the suite is reproducible */
static uint32_t rng_state;
static uint32_t xrand(void)
{
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    rng_state = x;
    return x;
}
static uint32_t xrange(uint32_t n) { return (n == 0) ? 0 : (xrand() % n); }

/* fixed geometry of the hardware / memory model */
static uint32_t WMAX;        /* max row width the line buffer holds (pixels) */
static uint32_t ADDR_WIDTH;
static uint32_t MEM_WORDS;
static uint32_t HALF;        /* src region < HALF <= dst region              */

#define MAXPIX (256u * 256u)
#define MAXWORD (MAXPIX / TEX_PPW)

typedef struct {
    uint32_t src, dst, src_w, src_h, dst_w, dst_h, scale_x, scale_y;
    uint32_t nw_src, nw_dst;   /* image sizes in memory words */
} rec_t;

static uint8_t  src_img[MAXPIX];
static uint8_t  dst_img[MAXPIX];
static uint8_t  chk_img[MAXPIX];
static uint32_t words[MAXWORD];

/* pack an 8-bit row-major image into 32-bit words (4 pixels/word) and write hex */
static void write_image_hex(const char *path, const uint8_t *pix,
                            uint32_t w, uint32_t h)
{
    uint32_t wpr = w / TEX_PPW;              /* words per row */
    uint32_t nw  = wpr * h;
    for (uint32_t r = 0; r < h; r++)
        for (uint32_t c = 0; c < wpr; c++) {
            const uint8_t *p = &pix[r * w + c * TEX_PPW];
            words[r * wpr + c] = (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                                 ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
        }
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    for (uint32_t i = 0; i < nw; i++) fprintf(f, "%08x\n", words[i]);
    fclose(f);
}

int main(int argc, char **argv)
{
    uint32_t nrand = 280, seed = 0x5EED0005u;
    const char *outdir = "tb/vectors";
    WMAX = 64; ADDR_WIDTH = 20; MEM_WORDS = 65536;

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--nrand")      && i+1<argc) nrand = strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--seed")       && i+1<argc) seed = strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--wmax")       && i+1<argc) WMAX = strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--addr-width") && i+1<argc) ADDR_WIDTH = strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--mem-words")  && i+1<argc) MEM_WORDS = strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--outdir")     && i+1<argc) outdir = argv[++i];
    }
    rng_state = seed ? seed : 0x1u;
    HALF = MEM_WORDS / 2;

    /* hand-picked corner cases: {src_w, src_h, dst_w, dst_h} */
    static const uint32_t corners[][4] = {
        {  4,  4,  4,  4 },   /* 1:1 identity copy (tiny)             */
        { 64, 64, 64, 64 },   /* 1:1 identity copy (full width)       */
        {  4,  4, 64, 64 },   /* 16x magnify                          */
        { 64, 64,  4,  4 },   /* 16x minify                           */
        { 64,  1, 32,  8 },   /* height-1 source: vertical clamp      */
        {  4, 64,  8,  8 },   /* tall source                          */
        { 32, 16,  8, 40 },   /* anisotropic: minify x, magnify y     */
        {  8,  8, 64,  4 },   /* magnify x, minify y                  */
        { 60, 60, 64, 64 },   /* non-integer scale, fractional weights*/
        { 12, 12, 64, 64 },   /* ~5.33x magnify                       */
    };
    uint32_t ncorner = (uint32_t)(sizeof(corners)/sizeof(corners[0]));
    uint32_t njobs = ncorner + nrand;

    static rec_t recs[4096];
    if (njobs > 4096) { fprintf(stderr, "too many jobs\n"); return 1; }

    char path[512];
    uint64_t total_pixels = 0, total_rows = 0, total_baseline = 0;
    uint32_t max_side = WMAX;
    uint32_t max_words = (max_side / TEX_PPW) * max_side;   /* biggest image */

    for (uint32_t j = 0; j < njobs; j++) {
        uint32_t sw, sh, dw, dh;
        if (j < ncorner) {
            sw = corners[j][0]; sh = corners[j][1];
            dw = corners[j][2]; dh = corners[j][3];
        } else {
            sw = 4u * (1u + xrange(WMAX / 4u));   /* 4..WMAX, multiple of 4 */
            dw = 4u * (1u + xrange(WMAX / 4u));
            sh = 1u + xrange(WMAX);               /* 1..WMAX               */
            dh = 1u + xrange(WMAX);
        }

        uint32_t nw_src = (sw / TEX_PPW) * sh;
        uint32_t nw_dst = (dw / TEX_PPW) * dh;

        /* place the two images in disjoint memory regions at random bases */
        uint32_t src_base = xrange(HALF - max_words);
        uint32_t dst_base = HALF + xrange(HALF - max_words);

        rec_t *R = &recs[j];
        R->src = src_base; R->dst = dst_base;
        R->src_w = sw; R->src_h = sh; R->dst_w = dw; R->dst_h = dh;
        R->scale_x = tex_scale(sw, dw);
        R->scale_y = tex_scale(sh, dh);
        R->nw_src = nw_src; R->nw_dst = nw_dst;

        /* random source image */
        for (uint32_t i = 0; i < sw * sh; i++) src_img[i] = (uint8_t)xrand();

        tex_job_t job = { src_base, dst_base, sw, sh, dw, dh,
                          R->scale_x, R->scale_y };

        tex_reference(src_img, dst_img, &job);                 /* golden      */
        total_baseline += tex_baseline_ops(src_img, chk_img, &job); /* + cost */
        if (memcmp(dst_img, chk_img, dw * dh) != 0) {
            fprintf(stderr, "internal: baseline != reference at job %u\n", j);
            return 1;
        }
        total_pixels += (uint64_t)dw * dh;
        total_rows   += dh;

        snprintf(path, sizeof path, "%s/src_%03u.hex", outdir, j);
        write_image_hex(path, src_img, sw, sh);
        snprintf(path, sizeof path, "%s/gold_%03u.hex", outdir, j);
        write_image_hex(path, dst_img, dw, dh);
    }

    /* jobs.txt manifest */
    snprintf(path, sizeof path, "%s/jobs.txt", outdir);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "%u %u %u %u %u\n", njobs, TEX_PIX_W, TEX_PPW, ADDR_WIDTH, WMAX);
    for (uint32_t j = 0; j < njobs; j++) {
        rec_t *R = &recs[j];
        fprintf(f, "%u %u %u %u %u %u %u %u %u %u %u\n",
                j, R->src, R->dst, R->src_w, R->src_h, R->dst_w, R->dst_h,
                R->scale_x, R->scale_y, R->nw_src, R->nw_dst);
    }
    fclose(f);

    /* params.vh */
    snprintf(path, sizeof path, "%s/params.vh", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "// auto-generated by tex_host - do not edit\n");
    fprintf(f, "localparam integer PIX_W      = %u;\n", TEX_PIX_W);
    fprintf(f, "localparam integer PPW        = %u;\n", TEX_PPW);
    fprintf(f, "localparam integer WORD_W     = %u;\n", TEX_PIX_W * TEX_PPW);
    fprintf(f, "localparam integer ADDR_WIDTH = %u;\n", ADDR_WIDTH);
    fprintf(f, "localparam integer WMAX       = %u;\n", WMAX);
    fprintf(f, "localparam integer IDXW       = 16;\n");
    fprintf(f, "localparam integer MEM_WORDS  = %u;\n", MEM_WORDS);
    fclose(f);

    /* sw_metrics.txt: scalar baseline cost model */
    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "cpp 33\n");
    fprintf(f, "jobs %u\n", njobs);
    fprintf(f, "total_output_pixels %llu\n", (unsigned long long)total_pixels);
    fprintf(f, "total_output_rows %llu\n",   (unsigned long long)total_rows);
    fprintf(f, "total_baseline_cycles %llu\n", (unsigned long long)total_baseline);
    fclose(f);

    printf("generated %u jobs (%u corner + %u random), %llu output pixels\n",
           njobs, ncorner, nrand, (unsigned long long)total_pixels);
    return 0;
}
