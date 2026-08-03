/* ============================================================================
 * arc_host.c - stimulus generator + golden producer for the all-reduce engine.
 *
 *   ./arc_host --nrand N --seed S --peak PN --nmax M --outdir DIR
 *
 * Builds a flat word-addressable memory image (descriptor ring + per-rank
 * source buffers + zeroed destination buffers), computes the bit-exact reduced
 * result with the reference model, and writes into DIR:
 *
 *   mem_init.hex   the initial memory image the RTL testbench $readmemh's
 *   golden.txt     one "addr value" line per expected destination word
 *   arc_const.vh   Verilog params (counts, R, P, bases, seed, peak descriptor)
 *   sw_metrics.txt scalar-baseline cost-model numbers for the metrics report
 *
 * Descriptor 0 is a single large collective (the peak-throughput micro-
 * benchmark).  It is followed by directed corner cases (single-element tail,
 * exactly-one-group, two-group tail, PROD, a SUM that wraps 32 bits, all-
 * negative MAX/MIN) and then N random collectives.
 * ==========================================================================*/
#include "arc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define R ARC_R
#define P ARC_P
#define MAXMEM 262144
#define MAXDESC 512

static uint32_t mem[MAXMEM];
static uint32_t top;                 /* bump allocator for the data region     */

static uint64_t rng_state;
static uint64_t xrng(void) {
    uint64_t z = (rng_state += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

/* descriptor spec captured before addresses are assigned */
enum { FILL_FULL, FILL_SMALL, FILL_BIG };
typedef struct { int op; uint32_t n; int fill; } spec_t;
static spec_t spec[MAXDESC];
static int    ndesc = 0;

static void add(int op, uint32_t n, int fill) {
    if (ndesc >= MAXDESC) return;
    spec[ndesc].op = op; spec[ndesc].n = n; spec[ndesc].fill = fill; ndesc++;
}

static uint32_t fill_word(int fill) {
    switch (fill) {
    case FILL_SMALL: return (uint32_t)(int32_t)((int)(xrng() % 15) - 7);   /* [-7,7]   */
    case FILL_BIG:   return (uint32_t)(0x40000000u + (uint32_t)(xrng() & 0x3FFFFFFFu)); /* large + */
    default:         return (uint32_t)xrng();                             /* full 32b */
    }
}

int main(int argc, char **argv)
{
    int      nrand = 40, nmax = 64;
    uint32_t peakn = 2048;
    uint64_t seed  = 0x0D14C0DEC0DE0D14ull;
    const char *outdir = "tb/vectors";
    int i, d;
    uint32_t e;

    for (i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--nrand")  && i+1 < argc) nrand = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--nmax")   && i+1 < argc) nmax  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--peak")   && i+1 < argc) peakn = (uint32_t)strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--seed")   && i+1 < argc) seed  = strtoull(argv[++i],0,0);
        else if (!strcmp(argv[i], "--outdir") && i+1 < argc) outdir = argv[++i];
    }
    rng_state = seed;

    /* -------------------- descriptor plan ---------------------------------- */
    add(ARC_OP_SUM,  peakn, FILL_FULL);     /* 0: peak micro-benchmark          */
    add(ARC_OP_SUM,  1,     FILL_FULL);     /* 1: single-element tail (mask)    */
    add(ARC_OP_MAX,  P,     FILL_FULL);     /* 2: exactly one full group        */
    add(ARC_OP_MIN,  P+1,   FILL_FULL);     /* 3: two groups, 1-lane tail       */
    add(ARC_OP_PROD, 6,     FILL_SMALL);    /* 4: product of small signed vals  */
    add(ARC_OP_SUM,  17,    FILL_BIG);      /* 5: SUM that wraps 32 bits         */
    add(ARC_OP_MAX,  13,    FILL_BIG);      /* 6: MAX over large magnitudes      */
    add(ARC_OP_MIN,  13,    FILL_FULL);     /* 7: MIN over full-range signed     */
    add(ARC_OP_PROD, 9,     FILL_SMALL);    /* 8: PROD, two groups + tail        */
    int directed = ndesc;
    for (d = 0; d < nrand; d++) {
        int op = (int)(xrng() & 3);
        uint32_t n = 1 + (uint32_t)(xrng() % (uint32_t)nmax);
        int fill = (op == ARC_OP_PROD) ? FILL_SMALL : FILL_FULL;
        add(op, n, fill);
    }

    /* -------------------- assign addresses --------------------------------- */
    uint32_t desc_words = (uint32_t)ndesc * ARC_DESC_W;
    top = desc_words;                        /* data region begins after ring   */
    uint32_t dst_base[MAXDESC];
    uint32_t src_base[MAXDESC][ARC_RMAX];

    for (d = 0; d < ndesc; d++) {
        for (i = 0; i < R; i++) { src_base[d][i] = top; top += spec[d].n; }
        dst_base[d] = top; top += spec[d].n;       /* dst left zeroed           */
    }
    uint32_t mem_words = top;
    if (mem_words > MAXMEM) { fprintf(stderr, "memory image too large\n"); return 1; }

    /* -------------------- fill descriptors + source data ------------------- */
    for (d = 0; d < ndesc; d++) {
        uint32_t db = (uint32_t)d * ARC_DESC_W;
        mem[db + ARC_D_CTRL] = (uint32_t)(spec[d].op & ARC_CTRL_OP_MASK) | ARC_CTRL_VALID;
        mem[db + ARC_D_N]    = spec[d].n;
        mem[db + ARC_D_DST]  = dst_base[d];
        for (i = 0; i < R; i++) mem[db + ARC_D_SRC0 + i] = src_base[d][i];
        for (i = 0; i < R; i++)
            for (e = 0; e < spec[d].n; e++)
                mem[src_base[d][i] + e] = fill_word(spec[d].fill);
    }

    /* -------------------- mem_init.hex (image before the engine runs) ------ */
    char path[512];
    snprintf(path, sizeof(path), "%s/mem_init.hex", outdir);
    FILE *fh = fopen(path, "w");
    if (!fh) { perror("mem_init"); return 1; }
    for (e = 0; e < mem_words; e++) fprintf(fh, "%08x\n", mem[e]);
    fclose(fh);

    /* -------------------- golden: reduce into a scratch copy --------------- */
    static uint32_t gold[MAXMEM];
    memcpy(gold, mem, sizeof(uint32_t) * mem_words);
    for (d = 0; d < ndesc; d++) arc_run_desc(gold, (uint32_t)d * ARC_DESC_W, R, P);

    snprintf(path, sizeof(path), "%s/golden.txt", outdir);
    FILE *fg = fopen(path, "w");
    long total_elems = 0, total_groups = 0;
    uint32_t peak_golden = spec[0].n;
    for (d = 0; d < ndesc; d++) {
        for (e = 0; e < spec[d].n; e++)
            fprintf(fg, "%u %08x\n", dst_base[d] + e, gold[dst_base[d] + e]);
        total_elems  += spec[d].n;
        total_groups += (spec[d].n + P - 1) / P;
    }
    fclose(fg);
    long num_golden = total_elems;

    /* -------------------- arc_const.vh ------------------------------------- */
    snprintf(path, sizeof(path), "%s/arc_const.vh", outdir);
    FILE *fc = fopen(path, "w");
    fprintf(fc, "`define NUM_DESC %d\n", ndesc);
    fprintf(fc, "`define NUM_DIRECTED %d\n", directed);
    fprintf(fc, "`define NUM_GOLDEN %ld\n", num_golden);
    fprintf(fc, "`define MEM_WORDS %u\n", mem_words);
    fprintf(fc, "`define CFG_R %d\n", R);
    fprintf(fc, "`define CFG_P %d\n", P);
    fprintf(fc, "`define CFG_DW %d\n", ARC_DW);
    fprintf(fc, "`define CFG_DESC_W %d\n", ARC_DESC_W);
    fprintf(fc, "`define PEAK_N %u\n", spec[0].n);
    fprintf(fc, "`define PEAK_GOLDEN %u\n", peak_golden);
    fprintf(fc, "`define EXP_GROUPS %ld\n", total_groups);
    fprintf(fc, "`define EXP_WORDS %ld\n", total_elems);
    fprintf(fc, "`define CFG_SEED 64'h%016llx\n", (unsigned long long)seed);
    fclose(fc);

    /* -------------------- sw_metrics.txt ----------------------------------- */
    long per = arc_baseline_cycles_per_element(R);
    snprintf(path, sizeof(path), "%s/sw_metrics.txt", outdir);
    FILE *fm = fopen(path, "w");
    fprintf(fm, "baseline_cycles_per_element %ld\n", per);
    fprintf(fm, "baseline_total_cycles %ld\n", per * total_elems);
    fprintf(fm, "baseline_peak_cycles %ld\n", per * (long)spec[0].n);
    fprintf(fm, "num_desc %d\n", ndesc);
    fprintf(fm, "num_directed %d\n", directed);
    fprintf(fm, "total_elements %ld\n", total_elems);
    fprintf(fm, "total_groups %ld\n", total_groups);
    fprintf(fm, "peak_elements %u\n", spec[0].n);
    fclose(fm);

    printf("arc_host: %d descriptors (%d directed + %d random), R=%d P=%d, "
           "%ld elements / %ld groups, mem=%u words -> %s\n",
           ndesc, directed, nrand, R, P, total_elems, total_groups,
           mem_words, outdir);
    return 0;
}
