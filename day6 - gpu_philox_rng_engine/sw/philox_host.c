/* ---------------------------------------------------------------------------
 * philox_host.c
 * Host / vector generator. Builds the differential test suite the SystemVerilog
 * testbench replays against the RTL:
 *
 *   - a known-answer self-test against the three published Random123
 *     philox4x32x10 vectors, so the golden model is anchored to the reference
 *     implementation before a single random job is generated;
 *   - random RNG jobs (random 64-bit key, random 128-bit base counter, random
 *     draw count) plus hand-picked corner cases (single draw, exact and partial
 *     lane-beat boundaries, all-zero and all-ones counter/key, and base counters
 *     placed right at 32-bit wrap points so the 128-bit carry chain is exercised
 *     across a job);
 *   - one golden output stream per job (hex, one 32-bit random word per line);
 *   - jobs.txt manifest (dst, ndraws, key, base counter, word count);
 *   - params.vh so the DUT elaborates at exactly the vectors' geometry;
 *   - sw_metrics.txt carrying the scalar-baseline cost model for the report.
 *
 * phx_reference() produces the golden data; phx_baseline_ops() is an independent
 * (hand-unrolled) implementation cross-checked to produce a bit-identical stream.
 * ------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "philox_accel.h"

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
static uint32_t LANES;
static uint32_t ADDR_WIDTH;
static uint32_t MEM_WORDS;

#define MAXDRAWS  512u
#define MAXBUF    (600u * PHX_WORDS_PER_DRAW)   /* biggest corner is 500 draws */

typedef struct {
    uint32_t dst, ndraws;
    uint32_t key[2];
    uint32_t ctr[4];
    uint32_t nwords;
} rec_t;

static uint32_t gold[MAXBUF];
static uint32_t chk [MAXBUF];

static void write_words_hex(const char *path, const uint32_t *w, uint32_t n)
{
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    for (uint32_t i = 0; i < n; i++) fprintf(f, "%08x\n", w[i]);
    fclose(f);
}

/* --- known-answer test against the published Random123 philox4x32x10 vectors --- */
static int kat_check(void)
{
    struct { uint32_t ctr[4], key[2], exp[4]; } kats[] = {
        { {0x00000000,0x00000000,0x00000000,0x00000000}, {0x00000000,0x00000000},
          {0x6627e8d5,0xe169c58d,0xbc57ac4c,0x9b00dbd8} },
        { {0xffffffff,0xffffffff,0xffffffff,0xffffffff}, {0xffffffff,0xffffffff},
          {0x408f276d,0x41c83b0e,0xa20bc7c6,0x6d5451fd} },
        { {0x243f6a88,0x85a308d3,0x13198a2e,0x03707344}, {0xa4093822,0x299f31d0},
          {0xd16cfe09,0x94fdcceb,0x5001e420,0x24126ea1} },
    };
    int fail = 0;
    for (uint32_t i = 0; i < sizeof(kats)/sizeof(kats[0]); i++) {
        uint32_t out[4];
        phx_block(kats[i].ctr, kats[i].key, out);
        int ok = (out[0]==kats[i].exp[0] && out[1]==kats[i].exp[1] &&
                  out[2]==kats[i].exp[2] && out[3]==kats[i].exp[3]);
        printf("  KAT %u: got %08x %08x %08x %08x  %s\n",
               i, out[0], out[1], out[2], out[3], ok ? "OK" : "MISMATCH");
        if (!ok) {
            printf("         exp %08x %08x %08x %08x\n",
                   kats[i].exp[0], kats[i].exp[1], kats[i].exp[2], kats[i].exp[3]);
            fail = 1;
        }
    }
    return fail;
}

int main(int argc, char **argv)
{
    uint32_t nrand = 280, seed = 0x5EED0006u;
    const char *outdir = "tb/vectors";
    LANES = 4; ADDR_WIDTH = 20; MEM_WORDS = 262144;

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--nrand")      && i+1<argc) nrand = strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--seed")       && i+1<argc) seed = strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--lanes")      && i+1<argc) LANES = strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--addr-width") && i+1<argc) ADDR_WIDTH = strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--mem-words")  && i+1<argc) MEM_WORDS = strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--outdir")     && i+1<argc) outdir = argv[++i];
    }
    rng_state = seed ? seed : 0x1u;

    printf("known-answer self-test (Random123 philox4x32x10):\n");
    if (kat_check()) { fprintf(stderr, "FATAL: KAT self-test failed\n"); return 1; }

    /* hand-picked corner cases: {ndraws, c0,c1,c2,c3, k0,k1} */
    const uint32_t L = LANES;
    struct { uint32_t nd, c0,c1,c2,c3, k0,k1; } corners[] = {
        { 1,          0,0,0,0,                          0,0 },              /* single draw, KAT-anchored     */
        { L,          0,0,0,0,                          0,0 },              /* exactly one full lane-beat    */
        { L-1,        0,0,0,0,                          0,0 },              /* partial single beat           */
        { L+1,        0,0,0,0,                          0,0 },              /* partial second beat           */
        { 2*L,        1,0,0,0,                          0,0 },              /* two full beats                */
        { 500,        7,0,0,0,                          0x12345678,0x9abcdef0 }, /* long run                 */
        { 7,          0xffffffff,0xffffffff,0xffffffff,0xffffffff, 0xffffffff,0xffffffff }, /* all-ones      */
        { 3,          0x243f6a88,0x85a308d3,0x13198a2e,0x03707344, 0xa4093822,0x299f31d0 }, /* pi KAT range  */
        { 8,          0xfffffffd,0,0,0,                 0xdeadbeef,0xcafef00d }, /* carry c0 -> c1            */
        { 6,          0xffffffff,0xffffffff,0xffffffff,0x12345678, 0x00c0ffee,0 }, /* carry ripple to c3     */
        { 5,          0,0,0,1,                          0,0 },              /* high counter word set         */
        { 3*L+2,      0x55,0,0,0,                       0xa5a5a5a5,0x5a5a5a5a }, /* remainder 2               */
        { 3*L+3,      0xaa,0,0,0,                       0,0xffffffff },     /* remainder 3 (max partial)     */
        { 17,         0x0badf00d,0x8badf00d,0,0,        0x1,0x2 },          /* prime, remainder 1            */
    };
    uint32_t ncorner = (uint32_t)(sizeof(corners)/sizeof(corners[0]));
    uint32_t njobs = ncorner + nrand;

    static rec_t recs[4096];
    if (njobs > 4096) { fprintf(stderr, "too many jobs\n"); return 1; }

    char path[512];
    uint64_t total_draws = 0, total_words = 0, total_baseline = 0;

    for (uint32_t j = 0; j < njobs; j++) {
        rec_t *R = &recs[j];
        if (j < ncorner) {
            R->ndraws = corners[j].nd;
            R->ctr[0]=corners[j].c0; R->ctr[1]=corners[j].c1;
            R->ctr[2]=corners[j].c2; R->ctr[3]=corners[j].c3;
            R->key[0]=corners[j].k0; R->key[1]=corners[j].k1;
        } else {
            R->ndraws = 1u + xrange(MAXDRAWS);
            R->ctr[0]=xrand(); R->ctr[1]=xrand();
            R->ctr[2]=xrand(); R->ctr[3]=xrand();
            R->key[0]=xrand(); R->key[1]=xrand();
        }
        R->nwords = R->ndraws * PHX_WORDS_PER_DRAW;
        if (R->nwords > MAXBUF) { fprintf(stderr, "job %u too big\n", j); return 1; }
        R->dst = xrange(MEM_WORDS - MAXBUF);

        phx_job_t job = { R->dst, R->ndraws, { R->key[0], R->key[1] },
                          { R->ctr[0], R->ctr[1], R->ctr[2], R->ctr[3] } };

        phx_reference(&job, gold);                            /* golden       */
        total_baseline += phx_baseline_ops(&job, chk);        /* + cost model */
        if (memcmp(gold, chk, R->nwords * sizeof(uint32_t)) != 0) {
            fprintf(stderr, "internal: baseline != reference at job %u\n", j);
            return 1;
        }
        total_draws += R->ndraws;
        total_words += R->nwords;

        snprintf(path, sizeof path, "%s/gold_%03u.hex", outdir, j);
        write_words_hex(path, gold, R->nwords);
    }

    /* jobs.txt manifest */
    snprintf(path, sizeof path, "%s/jobs.txt", outdir);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "%u %u %u\n", njobs, LANES, ADDR_WIDTH);
    for (uint32_t j = 0; j < njobs; j++) {
        rec_t *R = &recs[j];
        fprintf(f, "%u %u %u %u %u %u %u %u %u %u\n",
                j, R->dst, R->ndraws, R->key[0], R->key[1],
                R->ctr[0], R->ctr[1], R->ctr[2], R->ctr[3], R->nwords);
    }
    fclose(f);

    /* params.vh */
    snprintf(path, sizeof path, "%s/params.vh", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "// auto-generated by philox_host - do not edit\n");
    fprintf(f, "localparam integer LANES      = %u;\n", LANES);
    fprintf(f, "localparam integer ROUNDS     = %u;\n", PHX_ROUNDS);
    fprintf(f, "localparam integer WORD_W     = %u;\n", LANES * 128u);
    fprintf(f, "localparam integer WPB        = %u;\n", LANES * PHX_WORDS_PER_DRAW);
    fprintf(f, "localparam integer ADDR_WIDTH = %u;\n", ADDR_WIDTH);
    fprintf(f, "localparam integer MEM_WORDS  = %u;\n", MEM_WORDS);
    fprintf(f, "localparam [31:0]  IDENT_VALUE = 32'h%08X;\n", PHX_IDENT_VALUE);
    fclose(f);

    /* sw_metrics.txt: scalar baseline cost model */
    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "lanes %u\n", LANES);
    fprintf(f, "opd %u\n", PHX_ROUNDS * 12u - 2u + 12u);   /* ops per draw core */
    fprintf(f, "jobs %u\n", njobs);
    fprintf(f, "total_draws %llu\n", (unsigned long long)total_draws);
    fprintf(f, "total_words %llu\n", (unsigned long long)total_words);
    fprintf(f, "total_baseline_cycles %llu\n", (unsigned long long)total_baseline);
    fclose(f);

    printf("generated %u jobs (%u corner + %u random), %llu draws / %llu words\n",
           njobs, ncorner, nrand, (unsigned long long)total_draws,
           (unsigned long long)total_words);
    return 0;
}
