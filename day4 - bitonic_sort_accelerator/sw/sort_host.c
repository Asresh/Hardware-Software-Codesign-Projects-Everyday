/* ---------------------------------------------------------------------------
 * sort_host.c
 * Host / vector generator. Builds the differential test suite the SystemVerilog
 * testbench replays against the RTL:
 *
 *   - random jobs (varied tile count, direction, and value distribution) plus a
 *     set of hand-picked corner cases (empty batch, single tile, the maximum
 *     batch, and adversarial data: all-equal, all-zero, all-ones for full-range
 *     unsigned compares, already-sorted and reverse-sorted tiles, and two-value
 *     duplicate-heavy tiles);
 *   - one source image and one golden output image per job (hex, one word/line);
 *   - jobs.txt manifest (src/dst word addresses, tile count, mode, word count);
 *   - params.vh so the DUT elaborates at exactly the vectors' geometry;
 *   - sw_metrics.txt carrying the scalar-baseline cycle model for the report.
 *
 * The engine's own reference (sort_reference) produces the golden data and the
 * scalar baseline (sort_baseline_cycles) supplies the software cost the hardware
 * is compared against.
 * ------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sort_accel.h"

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
static uint32_t MEM_WORDS;   /* total testbench memory (words) */
static uint32_t HALF;        /* src < HALF <= dst              */

typedef struct { uint32_t src, dst, ntiles, mode, nwords; } job_t;

static void write_hex(const char *path, const uint32_t *v, uint32_t n)
{
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    for (uint32_t i = 0; i < n; i++) fprintf(f, "%08x\n", v[i]);
    fclose(f);
}

/* fill nwords keys with a value distribution selected by `kind`; some kinds are
 * arranged per-tile so already-sorted / reverse-sorted inputs are exercised. */
static void gen_data(uint32_t *src, uint32_t nwords, int kind)
{
    for (uint32_t i = 0; i < nwords; i++) {
        uint32_t pos = i % SORT_N;   /* position within the tile */
        switch (kind) {
            case 0: src[i] = xrange(256);                 break; /* small random   */
            case 1: src[i] = xrand();                     break; /* full 32-bit    */
            case 2: src[i] = 0u;                          break; /* all zero       */
            case 3: src[i] = 0xFFFFFFFFu;                 break; /* all ones        */
            case 4: src[i] = pos;                         break; /* already ascending */
            case 5: src[i] = (SORT_N - 1u) - pos;         break; /* reverse sorted  */
            case 6: src[i] = (xrand() & 1u) ? 0xFFFFFFFFu : 0u;  /* two-value dup   */
                                                          break;
            default: src[i] = xrange(1u << 16);           break; /* bounded random  */
        }
    }
}

int main(int argc, char **argv)
{
    uint32_t n = SORT_N, width = 32, addr_width = 20, tile_width = 16;
    uint32_t nrand = 256, seed = 0xB1707u, max_tiles = 128;
    const char *outdir = "tb/vectors";

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--n")          && i+1 < argc) n          = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--width")      && i+1 < argc) width      = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--addr-width") && i+1 < argc) addr_width = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--tile-width") && i+1 < argc) tile_width = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--nrand")      && i+1 < argc) nrand      = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed")       && i+1 < argc) seed       = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--max-tiles")  && i+1 < argc) max_tiles  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--outdir")     && i+1 < argc) outdir     = argv[++i];
    }
    if (n != SORT_N) {
        fprintf(stderr, "this generator is built for SORT_N=%u (got --n %u)\n", SORT_N, n);
        return 1;
    }
    rng_state = seed ? seed : 1u;

    /* testbench memory sized to comfortably hold the largest job twice over */
    MEM_WORDS = 1u << 16;                 /* 65536 words */
    HALF      = MEM_WORDS / 2;
    if (max_tiles * n > HALF) { fprintf(stderr, "max_tiles too large\n"); return 1; }

    /* corner cases: {tile count, data kind} pairs, each run in both directions */
    struct { uint32_t ntiles; int kind; } corner[] = {
        {0, 2}, {1, 2}, {1, 3}, {1, 4}, {1, 5}, {1, 1},
        {2, 6}, {3, 4}, {3, 5}, {4, 6}, {8, 1}, {16, 6},
        {max_tiles, 1}, {max_tiles, 6}, {max_tiles, 3},
    };
    const uint32_t ncorner = sizeof(corner)/sizeof(corner[0]);
    uint32_t njobs = nrand + ncorner * 2;   /* each corner case in both modes */

    job_t *jobs = malloc(sizeof(job_t) * njobs);
    uint32_t *src  = malloc(sizeof(uint32_t) * (max_tiles * n + n));
    uint32_t *gold = malloc(sizeof(uint32_t) * (max_tiles * n + n));
    if (!jobs || !src || !gold) { fprintf(stderr, "oom\n"); return 1; }

    char path[512];
    uint32_t j = 0;
    uint64_t total_tiles = 0, total_keys = 0, total_baseline = 0;

    /* -------- corner cases: every case in both sort directions -------- */
    for (uint32_t c = 0; c < ncorner; c++) {
        for (uint32_t m = 0; m < 2; m++, j++) {
            uint32_t nt     = corner[c].ntiles;
            uint32_t nwords = nt * n;
            gen_data(src, nwords, corner[c].kind);
            sort_reference(src, gold, nt, (int)m);

            jobs[j].src    = (nwords ? xrange(HALF - nwords) : 0);
            jobs[j].dst    = HALF + (nwords ? xrange(HALF - nwords) : 0);
            jobs[j].ntiles = nt; jobs[j].mode = m; jobs[j].nwords = nwords;

            if (nwords) {
                snprintf(path, sizeof path, "%s/src_%03u.hex", outdir, j);
                write_hex(path, src, nwords);
                snprintf(path, sizeof path, "%s/gold_%03u.hex", outdir, j);
                write_hex(path, gold, nwords);
            }
            total_tiles    += nt;
            total_keys     += nwords;
            total_baseline += sort_baseline_cycles(nt);
        }
    }

    /* -------- random jobs -------- */
    for (uint32_t r = 0; r < nrand; r++, j++) {
        uint32_t nt     = 1 + xrange(max_tiles);      /* 1..max_tiles */
        uint32_t mode   = xrand() & 1u;
        int      kind   = (int)xrange(8);             /* full mix of distributions */
        uint32_t nwords = nt * n;
        gen_data(src, nwords, kind);
        sort_reference(src, gold, nt, (int)mode);

        jobs[j].src    = xrange(HALF - nwords);
        jobs[j].dst    = HALF + xrange(HALF - nwords);
        jobs[j].ntiles = nt; jobs[j].mode = mode; jobs[j].nwords = nwords;

        snprintf(path, sizeof path, "%s/src_%03u.hex", outdir, j);
        write_hex(path, src, nwords);
        snprintf(path, sizeof path, "%s/gold_%03u.hex", outdir, j);
        write_hex(path, gold, nwords);

        total_tiles    += nt;
        total_keys     += nwords;
        total_baseline += sort_baseline_cycles(nt);
    }

    /* -------- params.vh -------- */
    snprintf(path, sizeof path, "%s/params.vh", outdir);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "// auto-generated by sort_host - do not edit\n");
    fprintf(f, "localparam integer N          = %u;\n", n);
    fprintf(f, "localparam integer W          = %u;\n", width);
    fprintf(f, "localparam integer ADDR_WIDTH = %u;\n", addr_width);
    fprintf(f, "localparam integer TILE_WIDTH = %u;\n", tile_width);
    fprintf(f, "localparam integer MEM_WORDS  = %u;\n", MEM_WORDS);
    fclose(f);

    /* -------- jobs.txt manifest -------- */
    snprintf(path, sizeof path, "%s/jobs.txt", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "%u %u %u %u %u\n", njobs, n, width, addr_width, tile_width);
    for (uint32_t i = 0; i < njobs; i++)
        fprintf(f, "%u %u %u %u %u %u\n", i, jobs[i].src, jobs[i].dst,
                jobs[i].ntiles, jobs[i].mode, jobs[i].nwords);
    fclose(f);

    /* -------- sw_metrics.txt (baseline cost model) -------- */
    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "cpt %u\n", SORT_CPT);
    fprintf(f, "jobs %u\n", njobs);
    fprintf(f, "total_tiles %llu\n", (unsigned long long)total_tiles);
    fprintf(f, "total_keys %llu\n", (unsigned long long)total_keys);
    fprintf(f, "total_baseline_cycles %llu\n", (unsigned long long)total_baseline);
    fclose(f);

    printf("generated %u jobs (%u random + %u corner), %llu tiles / %llu keys, outdir=%s\n",
           njobs, nrand, ncorner * 2,
           (unsigned long long)total_tiles, (unsigned long long)total_keys, outdir);

    free(jobs); free(src); free(gold);
    return 0;
}
