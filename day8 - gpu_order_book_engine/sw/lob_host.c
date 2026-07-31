/* =============================================================================
 * lob_host.c - stimulus generator + golden model driver for the LOB engine.
 *
 * Builds a corpus of market-data message streams (hand-built corner cases plus
 * NRAND random streams), runs each through the golden reference book to produce
 * the expected best-bid/offer after every message, and writes:
 *
 *   tb/vectors/msgs_%03d.hex   one 64-bit packed message beat per line
 *   tb/vectors/bbo_%03d.hex    one 128-bit packed BBO record per line
 *   tb/vectors/jobs.hex        message count of each stream (one hex/line)
 *   tb/vectors/lob_const.vh    localparams shared with the testbench
 *   tb/vectors/sw_metrics.txt  baseline cost model + corpus totals
 *
 * The reference and the RTL derive every field offset from QW/PW, so the two
 * agree bit-for-bit.
 * ========================================================================== */
#include "lob.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------- deterministic RNG (xorshift64) ---------------- */
static uint64_t rng_s;
static uint64_t xr(void)
{
    uint64_t x = rng_s;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    rng_s = x;
    return x;
}
static uint32_t rnd(uint32_t lo, uint32_t hi) /* inclusive */
{
    return lo + (uint32_t)(xr() % (uint64_t)(hi - lo + 1));
}

/* ---------------- stream corpus ---------------- */
#ifndef MAX_MSGS
#define MAX_MSGS 64
#endif

typedef struct { msg_t m[MAX_MSGS]; int n; } stream_t;

static stream_t *streams;
static int       n_streams;
static int       cap_streams;

static stream_t *new_stream(void)
{
    if (n_streams == cap_streams) {
        cap_streams = cap_streams ? cap_streams * 2 : 64;
        streams = realloc(streams, (size_t)cap_streams * sizeof(*streams));
    }
    stream_t *s = &streams[n_streams++];
    s->n = 0;
    return s;
}
static void push(stream_t *s, uint32_t op, uint32_t side, uint32_t price, uint32_t qty)
{
    if (s->n >= MAX_MSGS) return;
    s->m[s->n].op = op; s->m[s->n].side = side;
    s->m[s->n].price = price & PRICE_MASK; s->m[s->n].qty = qty & QTY_MASK;
    s->n++;
}

/* ---------------- hand-built corner cases ---------------- */
static void build_corners(void)
{
    stream_t *s;

    /* 1: empty-book operations that must be no-ops (SUB/CLR on a miss) */
    s = new_stream();
    push(s, OP_SUB, SIDE_BID, 100, 5);
    push(s, OP_CLR, SIDE_ASK, 200, 0);
    push(s, OP_SUB, SIDE_ASK, 150, 9);

    /* 2: single bid then single ask -> both sides of BBO populate */
    s = new_stream();
    push(s, OP_ADD, SIDE_BID, 100, 10);
    push(s, OP_ADD, SIDE_ASK, 105, 7);

    /* 3: price collisions on the same level (aggregation) */
    s = new_stream();
    push(s, OP_ADD, SIDE_BID, 100, 5);
    push(s, OP_ADD, SIDE_BID, 100, 5);
    push(s, OP_ADD, SIDE_BID, 100, 5);
    push(s, OP_SUB, SIDE_BID, 100, 8);   /* 15 -> 7 */

    /* 4: improving then removing the best bid -> BBO steps down */
    s = new_stream();
    push(s, OP_ADD, SIDE_BID,  98, 3);
    push(s, OP_ADD, SIDE_BID,  99, 4);
    push(s, OP_ADD, SIDE_BID, 100, 5);   /* best = 100 */
    push(s, OP_CLR, SIDE_BID, 100, 0);   /* best -> 99  */
    push(s, OP_CLR, SIDE_BID,  99, 0);   /* best -> 98  */

    /* 5: improving then removing the best ask -> BBO steps up */
    s = new_stream();
    push(s, OP_ADD, SIDE_ASK, 110, 3);
    push(s, OP_ADD, SIDE_ASK, 108, 4);
    push(s, OP_ADD, SIDE_ASK, 106, 5);   /* best = 106 */
    push(s, OP_SUB, SIDE_ASK, 106, 5);   /* -> 0, free; best -> 108 */

    /* 6: SUB below zero clamps and frees the level */
    s = new_stream();
    push(s, OP_ADD, SIDE_BID, 100, 4);
    push(s, OP_SUB, SIDE_BID, 100, 10);  /* clamp to 0, free */
    push(s, OP_SUB, SIDE_BID, 100, 1);   /* now a miss: no-op */

    /* 7: SET to a value, SET to zero frees, re-ADD */
    s = new_stream();
    push(s, OP_SET, SIDE_ASK, 200, 12);
    push(s, OP_SET, SIDE_ASK, 200, 0);   /* free */
    push(s, OP_ADD, SIDE_ASK, 200, 3);   /* re-alloc */

    /* 8: overflow - more distinct levels than the CAM can hold */
    s = new_stream();
    for (uint32_t i = 0; i < (uint32_t)N_LEVELS + 8u; i++)
        push(s, OP_ADD, SIDE_BID, 1000 + i, 1);   /* last 8 overflow */
    /* free one, then a new distinct level should now fit */
    push(s, OP_CLR, SIDE_BID, 1000, 0);
    push(s, OP_ADD, SIDE_BID, 5000, 9);

    /* 9: max-value price/qty edges */
    s = new_stream();
    push(s, OP_ADD, SIDE_BID, PRICE_MASK, QTY_MASK);
    push(s, OP_ADD, SIDE_ASK, PRICE_MASK, 1);
    push(s, OP_ADD, SIDE_BID, 0, 1);            /* lowest possible price */
    push(s, OP_SUB, SIDE_BID, PRICE_MASK, 1);   /* wrap guard: QTY_MASK-1 */

    /* 10: full churn - alternating add/remove of the top of book */
    s = new_stream();
    for (int i = 0; i < 12; i++) {
        push(s, OP_ADD, SIDE_BID, 300 + (uint32_t)(i & 3), 2);
        push(s, OP_CLR, SIDE_BID, 300 + (uint32_t)(i & 3), 0);
    }
}

/* ---------------- random streams ---------------- */
static void build_random(int nrand)
{
    for (int i = 0; i < nrand; i++) {
        stream_t *s = new_stream();
        int len = (int)rnd(1, MAX_MSGS);
        /* narrow price window forces collisions + both hits and misses;
           every ~7th stream uses a wide window to exercise overflow */
        uint32_t span = (i % 7 == 0) ? (uint32_t)(N_LEVELS + 24) : 12u;
        uint32_t base = rnd(50, 4000);
        for (int k = 0; k < len; k++) {
            uint32_t op    = rnd(0, 3);
            uint32_t side  = rnd(0, 1);
            uint32_t price = base + rnd(0, span);
            uint32_t qty   = rnd(0, 1) ? rnd(1, 50) : rnd(0, (QTY_MASK > 4096 ? 4096 : QTY_MASK));
            push(s, op, side, price, qty);
        }
    }
}

/* ---------------- vector emission ---------------- */
/* emit a stream, zero-padded to `pad` lines so the testbench $readmemh reads a
   full fixed-size memory without short-file warnings */
static void emit_stream(const char *outdir, int idx, const stream_t *s,
                        int pad, uint64_t *checks)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/msgs_%03d.hex", outdir, idx);
    FILE *fm = fopen(path, "w");
    snprintf(path, sizeof(path), "%s/bbo_%03d.hex", outdir, idx);
    FILE *fb = fopen(path, "w");
    if (!fm || !fb) { perror("open vector"); exit(1); }

    lob_reset();
    for (int k = 0; k < s->n; k++) {
        uint64_t beat = msg_pack(&s->m[k]);
        fprintf(fm, "%016llx\n", (unsigned long long)beat);

        lob_apply(&s->m[k]);
        bbo_t b; lob_bbo(&b);
        uint64_t hi, lo; bbo_pack(&b, &hi, &lo);
        fprintf(fb, "%016llx%016llx\n",
                (unsigned long long)hi, (unsigned long long)lo);
        (*checks)++;
    }
    for (int k = s->n; k < pad; k++) {            /* zero padding */
        fprintf(fm, "%016llx\n", 0ULL);
        fprintf(fb, "%016llx%016llx\n", 0ULL, 0ULL);
    }
    fclose(fm); fclose(fb);
}

int main(int argc, char **argv)
{
    int         nrand  = 256;
    uint64_t    seed   = 0x5EED0008ULL;
    const char *outdir = "tb/vectors";

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--nrand")  && i + 1 < argc) nrand  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--outdir") && i + 1 < argc) outdir = argv[++i];
    }
    rng_s = seed ? seed : 1;

    build_corners();
    int n_corner = n_streams;
    build_random(nrand);

    /* ---- longest stream sets the padded vector-file length ---- */
    int max_msgs = 0;
    for (int i = 0; i < n_streams; i++)
        if (streams[i].n > max_msgs) max_msgs = streams[i].n;

    /* ---- emit vectors + golden, accumulate corpus stats ---- */
    uint64_t total_msgs = 0, total_checks = 0;
    uint64_t base_total = 0, base_peak = 0;
    int      overflow_streams = 0;

    char path[512];
    snprintf(path, sizeof(path), "%s/jobs.hex", outdir);
    FILE *fj = fopen(path, "w");
    if (!fj) { perror("open jobs"); return 1; }

    for (int i = 0; i < n_streams; i++) {
        emit_stream(outdir, i, &streams[i], max_msgs, &total_checks);
        fprintf(fj, "%08x\n", (unsigned)streams[i].n);
        total_msgs += (uint64_t)streams[i].n;

        uint64_t t = 0, p = 0;
        lob_baseline_stats(streams[i].m, streams[i].n, &t, &p);
        base_total += t;
        if (p > base_peak) base_peak = p;

        lob_reset();
        for (int k = 0; k < streams[i].n; k++) lob_apply(&streams[i].m[k]);
        if (lob_overflow()) overflow_streams++;
    }
    fclose(fj);

    /* ---- generated Verilog constants for the testbench ---- */
    snprintf(path, sizeof(path), "%s/lob_const.vh", outdir);
    FILE *fc = fopen(path, "w");
    fprintf(fc, "// generated by lob_host - do not edit\n");
    fprintf(fc, "localparam integer QW        = %d;\n", QW);
    fprintf(fc, "localparam integer PW        = %d;\n", PW);
    fprintf(fc, "localparam integer N_LEVELS  = %d;\n", N_LEVELS);
    fprintf(fc, "localparam integer MSGW      = %d;\n", MSGW);
    fprintf(fc, "localparam integer BBOW      = %d;\n", BBOW);
    fprintf(fc, "localparam integer N_STREAMS = %d;\n", n_streams);
    fprintf(fc, "localparam integer MAX_MSGS  = %d;\n", max_msgs);
    fprintf(fc, "localparam integer MSG_QTY_LSB   = %d;\n", MSG_QTY_LSB);
    fprintf(fc, "localparam integer MSG_PRICE_LSB = %d;\n", MSG_PRICE_LSB);
    fprintf(fc, "localparam integer MSG_SIDE_LSB  = %d;\n", MSG_SIDE_LSB);
    fprintf(fc, "localparam integer MSG_OP_LSB    = %d;\n", MSG_OP_LSB);
    fclose(fc);

    /* ---- design parameters for elaboration overrides ---- */
    snprintf(path, sizeof(path), "%s/params.vh", outdir);
    FILE *fp = fopen(path, "w");
    fprintf(fp, "// generated by lob_host - design parameters\n");
    fprintf(fp, "`define QW %d\n", QW);
    fprintf(fp, "`define PW %d\n", PW);
    fprintf(fp, "`define N_LEVELS %d\n", N_LEVELS);
    fclose(fp);

    /* ---- baseline cost model + corpus totals ---- */
    snprintf(path, sizeof(path), "%s/sw_metrics.txt", outdir);
    FILE *fs = fopen(path, "w");
    fprintf(fs, "STREAMS %d\n", n_streams);
    fprintf(fs, "CORNER_STREAMS %d\n", n_corner);
    fprintf(fs, "RANDOM_STREAMS %d\n", nrand);
    fprintf(fs, "TOTAL_MSGS %llu\n", (unsigned long long)total_msgs);
    fprintf(fs, "TOTAL_CHECKS %llu\n", (unsigned long long)total_checks);
    fprintf(fs, "MAX_MSGS %d\n", max_msgs);
    fprintf(fs, "OVERFLOW_STREAMS %d\n", overflow_streams);
    fprintf(fs, "BASELINE_CYCLES_TOTAL %llu\n", (unsigned long long)base_total);
    fprintf(fs, "BASELINE_PEAK_PERMSG %llu\n", (unsigned long long)base_peak);
    fclose(fs);

    printf("lob_host: %d streams (%d corner + %d random), %llu messages, "
           "%llu golden BBO records, %d overflow streams\n",
           n_streams, n_corner, nrand,
           (unsigned long long)total_msgs, (unsigned long long)total_checks,
           overflow_streams);
    free(streams);
    return 0;
}
