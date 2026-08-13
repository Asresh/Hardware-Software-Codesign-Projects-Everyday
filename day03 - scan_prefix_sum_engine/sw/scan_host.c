/* ---------------------------------------------------------------------------
 * scan_host.c
 * Host / vector generator. Builds the differential test suite that the
 * SystemVerilog testbench replays against the RTL:
 *
 *   - random jobs (varied length, mode, addresses, value ranges) plus a set of
 *     hand-picked corner cases (empty, single element, exactly one tile, tile
 *     boundary +/-1, all-zero and all-ones data for 32-bit wraparound);
 *   - one source image and one golden output image per job (hex, one word/line);
 *   - jobs.txt manifest (src/dst word addresses, length, mode, padded length);
 *   - params.vh so the DUT elaborates at exactly the vectors' geometry;
 *   - sw_metrics.txt carrying the scalar-baseline cycle model for the report.
 *
 * The engine's own reference (scan_reference) produces the golden data, and the
 * scalar baseline (scan_baseline_cycles) supplies the software cost the
 * hardware is compared against.
 * ------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "scan_accel.h"

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

/* memory layout: source region in the low half, destination in the high half */
static uint32_t MEM_WORDS;   /* total testbench memory (words)      */
static uint32_t HALF;        /* src < HALF <= dst                    */
static uint32_t LANES_G;

typedef struct { uint32_t src, dst, len, mode, padlen; } job_t;

static void write_hex(const char *path, const uint32_t *v, uint32_t n)
{
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    for (uint32_t i = 0; i < n; i++) fprintf(f, "%08x\n", v[i]);
    fclose(f);
}

static uint32_t padlen_of(uint32_t len)
{
    return ((len + LANES_G - 1) / LANES_G) * LANES_G;
}

/* fill src[0..len) with a value distribution selected by `kind` */
static void gen_data(uint32_t *src, uint32_t len, int kind)
{
    for (uint32_t i = 0; i < len; i++) {
        switch (kind) {
            case 0:  src[i] = xrange(256);          break; /* small, no overflow */
            case 1:  src[i] = xrand();              break; /* full 32-bit range   */
            case 2:  src[i] = 0u;                   break; /* all zero            */
            case 3:  src[i] = 0xFFFFFFFFu;          break; /* all ones (wrap)     */
            default: src[i] = xrange(1u << 20);     break;
        }
    }
}

int main(int argc, char **argv)
{
    uint32_t lanes = 16, width = 32, addr_width = 20, len_width = 20;
    uint32_t nrand = 256, seed = 0xC0FFEEu, max_len = 2048;
    const char *outdir = "tb/vectors";

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--lanes")      && i+1 < argc) lanes      = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--width")      && i+1 < argc) width      = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--addr-width") && i+1 < argc) addr_width = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--len-width")  && i+1 < argc) len_width  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--nrand")      && i+1 < argc) nrand      = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed")       && i+1 < argc) seed       = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--max-len")    && i+1 < argc) max_len    = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--outdir")     && i+1 < argc) outdir     = argv[++i];
    }
    rng_state = seed ? seed : 1u;
    LANES_G   = lanes;

    /* testbench memory sized to comfortably hold the largest job twice over */
    MEM_WORDS = 1u << 16;                 /* 65536 words */
    HALF      = MEM_WORDS / 2;
    if (padlen_of(max_len) > HALF) { fprintf(stderr, "max_len too large\n"); return 1; }

    static const uint32_t corner[] = {
        0, 1, 2, 3, 15, 16, 17, 31, 32, 33, 63, 64, 65, 255, 256, 257, 1023, 1024
    };
    const uint32_t ncorner = sizeof(corner)/sizeof(corner[0]);
    uint32_t njobs = nrand + ncorner * 2;   /* each corner len in both modes */

    job_t *jobs = malloc(sizeof(job_t) * njobs);
    uint32_t *src  = malloc(sizeof(uint32_t) * (max_len + lanes));
    uint32_t *gold = malloc(sizeof(uint32_t) * (max_len + lanes));
    if (!jobs || !src || !gold) { fprintf(stderr, "oom\n"); return 1; }

    char path[512];
    uint32_t j = 0;
    uint64_t total_elems = 0, total_baseline = 0;

    /* -------- corner cases: every length in both scan modes -------- */
    for (uint32_t c = 0; c < ncorner; c++) {
        for (uint32_t m = 0; m < 2; m++, j++) {
            uint32_t len  = corner[c];
            int      kind = (c & 1) ? 3 : 2;               /* all-ones / all-zero */
            uint32_t pad  = padlen_of(len);
            gen_data(src, len, kind);
            for (uint32_t k = len; k < pad; k++) src[k] = 0u; /* zero the tail */
            scan_reference(src, gold, len, (int)m);

            jobs[j].src = (pad ? xrange(HALF - pad) : 0);
            jobs[j].dst = HALF + (len ? xrange(HALF - len) : 0);
            jobs[j].len = len; jobs[j].mode = m; jobs[j].padlen = pad;

            snprintf(path, sizeof path, "%s/src_%03u.hex", outdir, j);
            write_hex(path, src, pad);
            snprintf(path, sizeof path, "%s/gold_%03u.hex", outdir, j);
            write_hex(path, gold, len);

            total_elems    += len;
            total_baseline += scan_baseline_cycles(len);
        }
    }

    /* -------- random jobs -------- */
    for (uint32_t r = 0; r < nrand; r++, j++) {
        uint32_t len  = 1 + xrange(max_len);       /* 1..max_len */
        uint32_t mode = xrand() & 1u;
        int      kind = (int)xrange(3);            /* small / full / bounded */
        if (kind == 2) kind = 4;                   /* skip all-zero here */
        uint32_t pad  = padlen_of(len);
        gen_data(src, len, kind);
        for (uint32_t k = len; k < pad; k++) src[k] = 0u;
        scan_reference(src, gold, len, (int)mode);

        jobs[j].src = xrange(HALF - pad);
        jobs[j].dst = HALF + xrange(HALF - len);
        jobs[j].len = len; jobs[j].mode = mode; jobs[j].padlen = pad;

        snprintf(path, sizeof path, "%s/src_%03u.hex", outdir, j);
        write_hex(path, src, pad);
        snprintf(path, sizeof path, "%s/gold_%03u.hex", outdir, j);
        write_hex(path, gold, len);

        total_elems    += len;
        total_baseline += scan_baseline_cycles(len);
    }

    /* -------- params.vh -------- */
    snprintf(path, sizeof path, "%s/params.vh", outdir);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "// auto-generated by scan_host - do not edit\n");
    fprintf(f, "localparam integer LANES      = %u;\n", lanes);
    fprintf(f, "localparam integer W          = %u;\n", width);
    fprintf(f, "localparam integer ADDR_WIDTH = %u;\n", addr_width);
    fprintf(f, "localparam integer LEN_WIDTH  = %u;\n", len_width);
    fprintf(f, "localparam integer MEM_WORDS  = %u;\n", MEM_WORDS);
    fclose(f);

    /* -------- jobs.txt manifest -------- */
    snprintf(path, sizeof path, "%s/jobs.txt", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "%u %u %u %u %u\n", njobs, lanes, width, addr_width, len_width);
    for (uint32_t i = 0; i < njobs; i++)
        fprintf(f, "%u %u %u %u %u %u\n", i, jobs[i].src, jobs[i].dst,
                jobs[i].len, jobs[i].mode, jobs[i].padlen);
    fclose(f);

    /* -------- sw_metrics.txt (baseline cost model) -------- */
    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "cpe %u\n", SCAN_CPE);
    fprintf(f, "jobs %u\n", njobs);
    fprintf(f, "total_elems %llu\n", (unsigned long long)total_elems);
    fprintf(f, "total_baseline_cycles %llu\n", (unsigned long long)total_baseline);
    fclose(f);

    printf("generated %u jobs (%u random + %u corner), %llu elements, outdir=%s\n",
           njobs, nrand, ncorner * 2, (unsigned long long)total_elems, outdir);

    free(jobs); free(src); free(gold);
    return 0;
}
