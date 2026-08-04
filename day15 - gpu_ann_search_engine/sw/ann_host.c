/* ============================================================================
 * ann_host.c - stimulus generator + golden producer for the ANN search engine.
 *
 *   ./ann_host --nrand N --nmax M --peak PN --seed S --outdir DIR
 *
 * For a mix of directed and randomised searches it builds the AXI4-Stream
 * database image, computes the bit-exact top-K with the reference model, and
 * writes into DIR:
 *
 *   stream.hex     the AXI4-Stream beats (P int8 elements / 64-bit beat) the
 *                  testbench $readmemh's and replays into the DUT ingress
 *   searches.txt   per-search {metric,n,kvalid, query words, golden top-K}
 *   ann_const.vh   Verilog params (D,P,K, search count, total beats, seed)
 *   sw_metrics.txt scalar-baseline cost-model totals for the metrics report
 *
 * Search 0 is a large L2 shard (the peak-throughput micro-benchmark).  It is
 * followed by directed corner cases (single vector, exactly-K, fewer-than-K, a
 * guaranteed zero-distance hit, all-identical ties, an inner-product argmax, IP
 * ties, and int8 saturation extremes) and then N randomised searches.
 * ==========================================================================*/
#include "ann.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXN 4096

static uint64_t rng_state;
static uint64_t xrng(void) {
    uint64_t z = (rng_state += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}
static int8_t rnd8(void)  { return (int8_t)(xrng() & 0xFF); }
static int8_t sat8(void)  { return (xrng() & 1) ? (int8_t)127 : (int8_t)-128; }

/* generation kinds */
enum { K_RAND, K_IDENT, K_QEQ, K_SAT };
typedef struct { int metric; int n; int kind; } spec_t;

static spec_t spec[MAXN];
static int nspec = 0;
static void add(int metric, int n, int kind) {
    spec[nspec].metric = metric; spec[nspec].n = n; spec[nspec].kind = kind; nspec++;
}

/* scratch buffers reused per search */
static int8_t q[ANN_D];
static int8_t db[(long)MAXN * ANN_D];

int main(int argc, char **argv)
{
    int nrand = 40, nmax = 256;
    int peakn = 2048;
    uint64_t seed = 0x0D15A11C0DE0D15ull;
    const char *outdir = "tb/vectors";
    int i;

    for (i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--nrand")  && i+1 < argc) nrand = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--nmax")   && i+1 < argc) nmax  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--peak")   && i+1 < argc) peakn = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed")   && i+1 < argc) seed  = strtoull(argv[++i],0,0);
        else if (!strcmp(argv[i], "--outdir") && i+1 < argc) outdir = argv[++i];
    }
    rng_state = seed;

    /* -------------------- search plan -------------------------------------- */
    add(ANN_METRIC_L2, peakn,     K_RAND);   /* 0: peak micro-benchmark        */
    add(ANN_METRIC_L2, 1,         K_RAND);   /* 1: single vector               */
    add(ANN_METRIC_L2, ANN_K,     K_RAND);   /* 2: exactly K                   */
    add(ANN_METRIC_L2, ANN_K - 1, K_RAND);   /* 3: fewer than K                */
    add(ANN_METRIC_L2, 64,        K_QEQ);    /* 4: guaranteed zero-distance hit */
    add(ANN_METRIC_L2, 32,        K_IDENT);  /* 5: all identical -> ties       */
    add(ANN_METRIC_IP, 100,       K_RAND);   /* 6: inner-product argmax        */
    add(ANN_METRIC_IP, 32,        K_IDENT);  /* 7: IP ties                     */
    add(ANN_METRIC_L2, 48,        K_SAT);    /* 8: int8 saturation extremes    */
    int directed = nspec;
    for (i = 0; i < nrand; i++) {
        int metric = (int)(xrng() & 1);
        int n = 1 + (int)(xrng() % (uint64_t)nmax);
        int kind = ((xrng() & 7) == 0) ? K_QEQ : K_RAND;
        add(metric, n, kind);
    }

    /* -------------------- open outputs ------------------------------------- */
    char path[512];
    snprintf(path, sizeof path, "%s/stream.hex", outdir);
    FILE *fs = fopen(path, "w");
    snprintf(path, sizeof path, "%s/searches.txt", outdir);
    FILE *fq = fopen(path, "w");
    if (!fs || !fq) { fprintf(stderr, "cannot open outputs in %s\n", outdir); return 1; }

    uint64_t total_beats = 0, total_vecs = 0, baseline_cycles = 0;
    int d, v, s;

    for (s = 0; s < nspec; s++) {
        int metric = spec[s].metric, n = spec[s].n, kind = spec[s].kind;

        /* query */
        for (d = 0; d < ANN_D; d++)
            q[d] = (kind == K_SAT) ? sat8() : rnd8();

        /* database */
        if (kind == K_IDENT) {
            int8_t base[ANN_D];
            for (d = 0; d < ANN_D; d++) base[d] = rnd8();
            for (v = 0; v < n; v++)
                for (d = 0; d < ANN_D; d++) db[(long)v*ANN_D + d] = base[d];
        } else {
            for (v = 0; v < n; v++)
                for (d = 0; d < ANN_D; d++)
                    db[(long)v*ANN_D + d] = (kind == K_SAT) ? sat8() : rnd8();
        }
        if (kind == K_QEQ) {                         /* plant an exact match   */
            int j = (int)(xrng() % (uint64_t)n);
            for (d = 0; d < ANN_D; d++) db[(long)j*ANN_D + d] = q[d];
        }

        /* stream beats: P elements per beat, CHUNKS beats per vector.  Each
         * beat is a P*8-bit word with lane l at bits [l*8 +: 8]; $readmemh is
         * MSB-first, so emit lane P-1 down to lane 0.  This is width-generic
         * (works for any P, unlike a fixed 64-bit pack).                      */
        for (v = 0; v < n; v++) {
            for (int c = 0; c < ANN_CHUNKS; c++) {
                for (int l = ANN_P - 1; l >= 0; l--) {
                    uint8_t b = (uint8_t)db[(long)v*ANN_D + c*ANN_P + l];
                    fprintf(fs, "%02x", b);
                }
                fprintf(fs, "\n");
            }
        }
        total_beats += (uint64_t)n * ANN_CHUNKS;
        total_vecs  += (uint64_t)n;
        baseline_cycles += ann_baseline_cycles(metric, n);

        /* golden top-K */
        ann_entry_t out[ANN_K];
        int kvalid = ann_topk_ref(metric, q, db, n, out);

        /* searches.txt record */
        fprintf(fq, "%d %d %d\n", metric, n, kvalid);
        for (int w = 0; w < REG_QUERY_WORDS; w++) {
            uint32_t word =  (uint32_t)(uint8_t)q[w*4+0]
                          | ((uint32_t)(uint8_t)q[w*4+1] << 8)
                          | ((uint32_t)(uint8_t)q[w*4+2] << 16)
                          | ((uint32_t)(uint8_t)q[w*4+3] << 24);
            fprintf(fq, "%08x ", word);
        }
        fprintf(fq, "\n");
        for (int k = 0; k < ANN_K; k++)
            fprintf(fq, "%08x %d\n", (uint32_t)out[k].score, out[k].id);
    }
    fclose(fs);
    fclose(fq);

    /* -------------------- constants header --------------------------------- */
    snprintf(path, sizeof path, "%s/ann_const.vh", outdir);
    FILE *fc = fopen(path, "w");
    fprintf(fc, "// auto-generated by ann_host - do not edit\n");
    fprintf(fc, "`define CFG_D %d\n", ANN_D);
    fprintf(fc, "`define CFG_P %d\n", ANN_P);
    fprintf(fc, "`define CFG_K %d\n", ANN_K);
    fprintf(fc, "`define CFG_CHUNKS %d\n", ANN_CHUNKS);
    fprintf(fc, "`define NUM_SEARCH %d\n", nspec);
    fprintf(fc, "`define NUM_DIRECTED %d\n", directed);
    fprintf(fc, "`define NUM_BEATS %llu\n", (unsigned long long)total_beats);
    fprintf(fc, "`define PEAK_SEARCH 0\n");
    fprintf(fc, "`define SEED 64'h%016llx\n", (unsigned long long)seed);
    fclose(fc);

    /* -------------------- scalar baseline metrics -------------------------- */
    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir);
    FILE *fm = fopen(path, "w");
    fprintf(fm, "baseline_cycles %llu\n", (unsigned long long)baseline_cycles);
    fprintf(fm, "searches %d\n", nspec);
    fprintf(fm, "total_vectors %llu\n", (unsigned long long)total_vecs);
    fprintf(fm, "total_beats %llu\n", (unsigned long long)total_beats);
    fprintf(fm, "d %d\n", ANN_D);
    fprintf(fm, "p %d\n", ANN_P);
    fprintf(fm, "k %d\n", ANN_K);
    fclose(fm);

    fprintf(stderr,
        "ann_host: %d searches, %llu vectors, %llu beats, baseline %llu cyc\n",
        nspec, (unsigned long long)total_vecs,
        (unsigned long long)total_beats, (unsigned long long)baseline_cycles);
    return 0;
}
