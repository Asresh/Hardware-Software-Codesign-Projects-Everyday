/* ---------------------------------------------------------------------------
 * sfu_host.c
 * Host / vector generator. Builds the differential test suite the SystemVerilog
 * testbench replays against the RTL:
 *
 *   - an accuracy self-test: every generated result is checked against IEEE
 *     double libm (sin/cos/exp/cosh/sinh/atan2/hypot/log/sqrt) and the maximum
 *     error is reported; the run aborts if the fixed-point CORDIC ever drifts
 *     past the tolerance, so the golden model is anchored to real analysis math
 *     before a single hardware comparison happens;
 *   - CORDIC jobs consuming a batch of function requests from a shared request
 *     ring and posting results to a completion ring, with random ring capacity,
 *     random head indices, and random disjoint ring bases so ring wraparound is
 *     exercised on nearly every job;
 *   - hand-picked corner cases: one request per op at a canonical point
 *     (sin 0, exp 0, ln 1, sqrt 1, ...), single-request jobs, count == capacity
 *     (maximum wrap), and heads placed at the very top of the ring so the walk
 *     wraps immediately;
 *   - per job: a request stream file (op,a,b per request) the testbench writes
 *     into the ring, and a golden result file (op,r0,r1 per request);
 *   - jobs.txt manifest (ring descriptor per job);
 *   - the CORDIC ROM (cordic_rom.hex) and params.vh so the DUT elaborates on
 *     exactly the model's constants;
 *   - sw_metrics.txt carrying the scalar-baseline cost model for the report.
 *
 * sfu_reference() produces the golden data; sfu_baseline_ops() is an independent
 * CORDIC implementation cross-checked to produce bit-identical results.
 * ------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "sfu_accel.h"

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
static double   xunit(void) { return (double)xrand() / 4294967296.0; }
static int32_t  toQ(double d) { return (int32_t)llround(d * (double)SFU_ONE_Q); }
static double   toD(int32_t q) { return (double)q / (double)SFU_ONE_Q; }

/* geometry */
static uint32_t LANES;
static uint32_t ADDR_WIDTH;
static uint32_t MEM_WORDS;

#define MAXCOUNT   96u
#define MAXCAP     256u
#define MAXREQW    (MAXCOUNT * SFU_ENTRY_WORDS)
#define MAXOUTW    (MAXCOUNT * 3u)

typedef struct {
    uint32_t req_base, res_base, ring_cap, req_head, res_head, count;
} desc_t;

static uint32_t reqbuf[MAXREQW];    /* op,a,b,pad per request                 */
static uint32_t gold  [MAXOUTW];    /* op,r0,r1 per request (golden)          */
static uint32_t chk   [MAXOUTW];    /* op,r0,r1 per request (baseline)        */

static double g_maxerr = 0.0;
static const char *g_worst = "";

/* build a valid random (op,a,b) request inside the op's convergence domain */
static void make_request(uint32_t op, int32_t *a, int32_t *b)
{
    double x, y;
    switch (op) {
        case SFU_OP_SINCOS:   *a = toQ(-1.5 + 3.0 * xunit()); *b = 0; break;
        case SFU_OP_EXP:
        case SFU_OP_COSHSINH: *a = toQ(-1.1 + 2.2 * xunit()); *b = 0; break;
        case SFU_OP_ATAN2:    y = -2.0 + 4.0 * xunit();
                              x =  0.05 + 1.95 * xunit();
                              *a = toQ(y); *b = toQ(x); break;
        case SFU_OP_LN:       *a = toQ(0.15 + 5.85 * xunit()); *b = 0; break;
        case SFU_OP_SQRT:     *a = toQ(0.03 + 2.27 * xunit()); *b = 0; break;
        default:              *a = 0; *b = 0; break;
    }
}

/* accuracy check of one golden result against libm; updates the max error */
static void acc_check(uint32_t op, int32_t a, int32_t b, int32_t r0, int32_t r1)
{
    double da = toD(a), db = toD(b), e0 = 0.0, e1 = 0.0;
    switch (op) {
        case SFU_OP_SINCOS:   e0 = fabs(toD(r0) - sin(da));
                              e1 = fabs(toD(r1) - cos(da)); break;
        case SFU_OP_EXP:      e0 = fabs(toD(r0) - exp(da));
                              e1 = fabs(toD(r1) - cosh(da)); break;
        case SFU_OP_COSHSINH: e0 = fabs(toD(r0) - cosh(da));
                              e1 = fabs(toD(r1) - sinh(da)); break;
        case SFU_OP_ATAN2:    e0 = fabs(toD(r0) - atan2(da, db));
                              e1 = fabs(toD(r1) - hypot(db, da)); break;
        case SFU_OP_LN:       e0 = fabs(toD(r0) - log(da));    break;
        case SFU_OP_SQRT:     e0 = fabs(toD(r0) - sqrt(da));   break;
        default: break;
    }
    if (e0 > g_maxerr) { g_maxerr = e0; g_worst = "r0"; }
    if (e1 > g_maxerr) { g_maxerr = e1; g_worst = "r1"; }
}

static void write_words_hex(const char *path, const uint32_t *w, uint32_t n)
{
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    for (uint32_t i = 0; i < n; i++) fprintf(f, "%08x\n", w[i]);
    fclose(f);
}

/* next power of two >= n, clamped to [16, MAXCAP] */
static uint32_t pow2_ceil(uint32_t n)
{
    uint32_t c = 16;
    while (c < n) c <<= 1;
    if (c > MAXCAP) c = MAXCAP;
    return c;
}

int main(int argc, char **argv)
{
    uint32_t nrand = 256, seed = 0x5EED0007u;
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

    sfu_init();

    /* emit the CORDIC ROM the RTL loads */
    char path[512];
    snprintf(path, sizeof path, "%s/cordic_rom.hex", outdir);
    if (sfu_emit_rom(path)) { fprintf(stderr, "cannot write %s\n", path); return 1; }

    /* ---- corner cases: one canonical request per op, and ring edge cases ---- */
    /* corner job list: {op, aQ, bQ, count-pattern} handled below */
    struct { uint32_t op; double a, b; } canon[] = {
        { SFU_OP_SINCOS,   0.0, 0 },    { SFU_OP_SINCOS,   1.5, 0 },
        { SFU_OP_SINCOS,  -1.5, 0 },    { SFU_OP_SINCOS,   0.7853981634, 0 },
        { SFU_OP_EXP,      0.0, 0 },    { SFU_OP_EXP,      1.1, 0 },
        { SFU_OP_EXP,     -1.1, 0 },    { SFU_OP_COSHSINH, 0.0, 0 },
        { SFU_OP_COSHSINH, 1.0, 0 },    { SFU_OP_ATAN2,    0.0, 1.0 },
        { SFU_OP_ATAN2,    1.0, 1.0 },  { SFU_OP_ATAN2,   -1.0, 0.05 },
        { SFU_OP_ATAN2,    2.0, 0.5 },  { SFU_OP_LN,       1.0, 0 },
        { SFU_OP_LN,       2.718281828, 0 }, { SFU_OP_LN,  0.15, 0 },
        { SFU_OP_LN,       6.0, 0 },    { SFU_OP_SQRT,     1.0, 0 },
        { SFU_OP_SQRT,     2.0, 0 },    { SFU_OP_SQRT,     0.03, 0 },
        { SFU_OP_SQRT,     0.25, 0 },   { SFU_OP_SQRT,     2.3, 0 },
    };
    uint32_t ncanon = (uint32_t)(sizeof(canon)/sizeof(canon[0]));

    /* number of jobs: a batch of canon-covering corner jobs + random jobs */
    uint32_t ncorner = 8;               /* structured ring/edge jobs */
    uint32_t njobs   = ncorner + nrand;
    static desc_t descs[4096];
    if (njobs > 4096) { fprintf(stderr, "too many jobs\n"); return 1; }

    FILE *fj = NULL;
    snprintf(path, sizeof path, "%s/jobs.txt", outdir);
    fj = fopen(path, "w");
    if (!fj) { perror(path); return 1; }
    fprintf(fj, "%u %u %u\n", njobs, LANES, ADDR_WIDTH);

    uint64_t total_req = 0, total_words = 0, total_baseline = 0;

    for (uint32_t j = 0; j < njobs; j++) {
        desc_t *D = &descs[j];
        uint32_t count;

        /* ---- choose the request count and ring geometry ---- */
        if (j == 0) {
            count = 1;                              /* single request        */
        } else if (j == 1) {
            count = ncanon;                         /* one canonical per op  */
        } else if (j < ncorner) {
            count = 8 + xrange(40);
        } else {
            count = 1 + xrange(MAXCOUNT);
        }
        if (count > MAXCOUNT) count = MAXCOUNT;

        uint32_t cap = pow2_ceil(count);
        D->ring_cap = cap;
        D->count    = count;

        /* corner jobs 2..7 force maximum wrap: head at top, count == cap */
        if (j >= 2 && j < ncorner) {
            D->count    = cap;                      /* fill the whole ring   */
            count       = cap;
            D->req_head = cap - 1u;                 /* wrap on the 2nd entry */
            D->res_head = cap - (2u % cap);
        } else if (j == 1) {
            D->req_head = cap - 1u;                 /* canon batch, wraps    */
            D->res_head = xrange(cap);
        } else {
            D->req_head = xrange(cap);
            D->res_head = xrange(cap);
        }

        /* disjoint ring bases: request ring low half, result ring high half */
        uint32_t ringw = cap * SFU_ENTRY_WORDS;
        uint32_t half  = MEM_WORDS / 2u;
        D->req_base = xrange(half - ringw);
        D->res_base = half + xrange(half - ringw);

        /* ---- fill the request stream ---- */
        for (uint32_t k = 0; k < count; k++) {
            uint32_t op; int32_t a, b;
            if (j == 1 && k < ncanon) {
                op = canon[k].op; a = toQ(canon[k].a); b = toQ(canon[k].b);
            } else {
                op = xrange(SFU_OP_COUNT);
                make_request(op, &a, &b);
            }
            reqbuf[k*SFU_ENTRY_WORDS+0] = op;
            reqbuf[k*SFU_ENTRY_WORDS+1] = (uint32_t)a;
            reqbuf[k*SFU_ENTRY_WORDS+2] = (uint32_t)b;
            reqbuf[k*SFU_ENTRY_WORDS+3] = 0u;
        }

        /* ---- golden + independent baseline (must agree) ---- */
        sfu_reference(reqbuf, count, gold);
        total_baseline += sfu_baseline_ops(reqbuf, count, chk);
        if (memcmp(gold, chk, count * 3u * sizeof(uint32_t)) != 0) {
            fprintf(stderr, "internal: baseline != reference at job %u\n", j);
            return 1;
        }

        /* ---- accuracy vs libm ---- */
        for (uint32_t k = 0; k < count; k++)
            acc_check(reqbuf[k*SFU_ENTRY_WORDS+0],
                      (int32_t)reqbuf[k*SFU_ENTRY_WORDS+1],
                      (int32_t)reqbuf[k*SFU_ENTRY_WORDS+2],
                      (int32_t)gold[k*3+1], (int32_t)gold[k*3+2]);

        /* ---- write per-job files ---- */
        snprintf(path, sizeof path, "%s/req_%03u.hex", outdir, j);
        write_words_hex(path, reqbuf, count * SFU_ENTRY_WORDS);
        snprintf(path, sizeof path, "%s/gold_%03u.hex", outdir, j);
        write_words_hex(path, gold, count * 3u);

        fprintf(fj, "%u %u %u %u %u %u %u\n",
                j, D->req_base, D->res_base, D->ring_cap,
                D->req_head, D->res_head, D->count);

        total_req   += count;
        total_words += count * 3u;
    }
    fclose(fj);

    /* accuracy gate: the fixed-point CORDIC must track libm */
    printf("CORDIC accuracy self-test (fixed-point Q4.28 vs IEEE double libm):\n");
    printf("  max abs error = %.3e  (worst %s)\n", g_maxerr, g_worst);
    if (g_maxerr > 1e-6) {
        fprintf(stderr, "FATAL: CORDIC accuracy %.3e exceeds 1e-6 tolerance\n",
                g_maxerr);
        return 1;
    }
    printf("  OK - within 1e-6 tolerance\n");

    /* sfu_const.vh: algorithm-fixed CORDIC constants, included by the RTL math
     * modules (cordic_core, sfu_decode, cordic_rom). No geometry here, so it is
     * identical across every elaboration and never clashes with the swept
     * LANES/ADDR_WIDTH top-level parameters. */
    snprintf(path, sizeof path, "%s/sfu_const.vh", outdir);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "// auto-generated by sfu_host - do not edit\n");
    fprintf(f, "localparam integer FBITS       = %u;\n", SFU_FBITS);
    fprintf(f, "localparam integer NC          = %u;\n", SFU_NC);
    fprintf(f, "localparam integer NH          = %u;\n", SFU_NH);
    fprintf(f, "localparam integer NROM        = %u;\n", SFU_NROM);
    fprintf(f, "localparam integer WORKW       = 40;\n");
    fprintf(f, "localparam signed [31:0] INV_KC = 32'sh%08X;\n", (uint32_t)sfu_invKc);
    fprintf(f, "localparam signed [31:0] INV_KH = 32'sh%08X;\n", (uint32_t)sfu_invKh);
    fprintf(f, "localparam signed [31:0] ONE_Q  = 32'sh%08X;\n", (uint32_t)SFU_ONE_Q);
    fprintf(f, "localparam signed [31:0] QTR_Q  = 32'sh%08X;\n", (uint32_t)SFU_QUARTER);
    fclose(f);

    /* params.vh: geometry the testbench elaborates the DUT at. */
    snprintf(path, sizeof path, "%s/params.vh", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "// auto-generated by sfu_host - do not edit\n");
    fprintf(f, "localparam integer LANES       = %u;\n", LANES);
    fprintf(f, "localparam integer ADDR_WIDTH  = %u;\n", ADDR_WIDTH);
    fprintf(f, "localparam integer MEM_WORDS   = %u;\n", MEM_WORDS);
    fprintf(f, "localparam integer ENTRY_WORDS = %u;\n", SFU_ENTRY_WORDS);
    fprintf(f, "localparam integer WORD_W      = %u;\n", LANES * 128u);
    fprintf(f, "localparam [31:0] IDENT_VALUE  = 32'h%08X;\n", SFU_IDENT_VALUE);
    fclose(f);

    /* sw_metrics.txt */
    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "lanes %u\n", LANES);
    fprintf(f, "jobs %u\n", njobs);
    fprintf(f, "total_requests %llu\n", (unsigned long long)total_req);
    fprintf(f, "total_words %llu\n", (unsigned long long)total_words);
    fprintf(f, "total_baseline_cycles %llu\n", (unsigned long long)total_baseline);
    fprintf(f, "max_abs_err_e9 %lld\n", (long long)llround(g_maxerr * 1e9));
    fclose(f);

    printf("generated %u jobs (%u corner + %u random), %llu requests / %llu result words\n",
           njobs, ncorner, nrand, (unsigned long long)total_req,
           (unsigned long long)total_words);
    return 0;
}
