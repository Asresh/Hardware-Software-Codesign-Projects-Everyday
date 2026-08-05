/* ============================================================================
 * kvp_host.c - host application: builds the workload, runs the golden model and
 * emits everything the Icarus testbench needs.
 *
 *   mem_init.hex   initial system-memory image (block table + request arrays)
 *   batches.txt    one record per batch: pool seed, request/result windows and
 *                  the expected cumulative statistics after the batch
 *   golden_res.hex expected result words, in order, across every batch
 *   golden_bt.hex  expected block-table contents after the whole run
 *   kvp_const.vh   geometry / sizes for the testbench
 *   sw_metrics.txt workload totals + the scalar baseline cost model
 *
 * The workload is a serving trace: cold prefills that allocate blocks, hot
 * re-reads that hit the translation cache, a cache flush, sequence eviction that
 * returns blocks to the pool (and is then re-prefilled so the LIFO reuse order
 * is checked), an out-of-memory storm, LRU thrash on one set, a peak-rate batch
 * and 320 randomised requests.
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kvp.h"

#define MAXB 32

typedef struct {
    int      reset;
    int      nfree;
    uint32_t freeblk[KVP_FREE_DEPTH];
    uint32_t reqw, resw;
    int      nreq;
    uint32_t nres, d_xlates;
    uint32_t c_reqs, c_xlates, c_hits, c_misses, c_allocs, c_frees, c_errs;
    uint32_t c_free;
    int      exp_oom;
    char     name[48];
} batch_t;

static batch_t  B[MAXB];
static int      NB = 0;
static uint32_t MEM[KVP_MEM_WORDS];
static uint32_t req_next = KVP_REQ_BASE_W;

/* ---------------- deterministic PRNG ---------------- */
static uint64_t rng_s = 0x0D16C0DEBEEF0001ull;
static uint32_t rnd(void)
{
    rng_s ^= rng_s << 13; rng_s ^= rng_s >> 7; rng_s ^= rng_s << 17;
    return (uint32_t)(rng_s >> 32);
}

/* ---------------- batch builders ---------------- */
static batch_t *bnew(const char *name, int reset)
{
    batch_t *b = &B[NB++];
    memset(b, 0, sizeof(*b));
    b->reset = reset;
    b->reqw  = req_next;
    snprintf(b->name, sizeof(b->name), "%s", name);
    return b;
}
static void badd(batch_t *b, uint32_t word)
{
    MEM[b->reqw + b->nreq] = word;
    b->nreq++;
    req_next++;
}
/* the pool cannot hold more than KVP_FREE_DEPTH blocks, and the engine ignores a
 * push into a full pool - so cap the seed list at the pool depth and let the
 * smaller-geometry sweep points simply run with a smaller pool */
static void bseed(batch_t *b, uint32_t blk)
{
    if (b->nfree < KVP_FREE_DEPTH) b->freeblk[b->nfree++] = blk;
}

/* ---------------- workload ---------------- */
static int peak_batch = 0;
static int lat_batch = 0;

static void build_workload(void)
{
    batch_t *b;
    int i, s;

    /* --- 0: cold prefill of a 8-block context: 8 allocations --- */
    b = bnew("cold prefill seq1 x8", 1);
    for (i = 0; i < 64; i++) bseed(b, 0x100u + (uint32_t)i);
    badd(b, kvp_req(OP_RANGE, 1, 8));

    /* --- 1: the same context again: every translation from the cache --- */
    b = bnew("hot re-read seq1 x8", 0);
    badd(b, kvp_req(OP_RANGE, 1, 8));

    /* --- 2: flush turns hits into block-table walks, but not allocations --- */
    b = bnew("flush + re-walk", 0);
    badd(b, kvp_req(OP_FLUSH, 0, 0));
    badd(b, kvp_req(OP_RANGE, 1, 8));

    /* --- 3: NOALLOC on a mapped and an unmapped block, then grow --- */
    b = bnew("noalloc mapped/unmapped", 0);
    badd(b, kvp_req(OP_NOALLOC, 1, 3));
    badd(b, kvp_req(OP_NOALLOC, 1, 40));
    badd(b, kvp_req(OP_XLATE,   1, 40));

    /* --- 4: evict the sequence, then re-prefill: LIFO reuse order --- */
    b = bnew("free seq1 + re-prefill", 0);
    badd(b, kvp_req(OP_FREE,  1, 64));
    badd(b, kvp_req(OP_RANGE, 1, 4));

    /* --- 5: pool exhaustion mid-range --- */
    b = bnew("oom storm (4 blocks, 10 asked)", 1);
    for (i = 0; i < 4; i++) bseed(b, 0x900u + (uint32_t)i);
    badd(b, kvp_req(OP_RANGE, 7, 10));

    /* --- 6: unknown opcode and the two degenerate zero-count forms --- */
    b = bnew("badop + zero-count ops", 0);
    badd(b, 0x90000000u);                       /* op = 9 */
    badd(b, kvp_req(OP_RANGE, 3, 0));
    badd(b, kvp_req(OP_FREE,  3, 0));

    /* --- 7: entries pre-populated by software, empty pool --- */
    b = bnew("host-populated rows, pool empty", 0);
    badd(b, kvp_req(OP_RANGE, 5, 4));

    /* --- 8: LRU thrash - 9 sequences contend for set 0 (logical 0), twice --- */
    b = bnew("LRU thrash on one set", 1);
    for (i = 0; i < 256; i++) bseed(b, 0x200u + (uint32_t)i);
    for (s = 0; s < 9; s++) badd(b, kvp_req(OP_XLATE, (uint32_t)s, 0));
    for (s = 0; s < 9; s++) badd(b, kvp_req(OP_XLATE, (uint32_t)s, 0));
    for (s = 8; s >= 0; s--) badd(b, kvp_req(OP_XLATE, (uint32_t)s, 0));

    /* --- 9: warm a 64-block context so it fits the cache exactly --- */
    b = bnew("warm 64-block context", 1);
    for (i = 0; i < 256; i++) bseed(b, 0x400u + (uint32_t)i);
    badd(b, kvp_req(OP_RANGE, 20, 64));

    /* --- 10: peak batch - 8 x 64 fully-cached translations --- */
    b = bnew("peak: 512 cached translations", 0);
    for (i = 0; i < 8; i++) badd(b, kvp_req(OP_RANGE, 20, 64));
    peak_batch = NB - 1;

    /* --- 11: latency probe - a single fully-cached translation --- */
    b = bnew("latency probe: 1 cached translation", 0);
    badd(b, kvp_req(OP_XLATE, 20, 5));
    lat_batch = NB - 1;

    /* --- 12..15: 320 randomised requests over the whole op mix --- */
    for (s = 0; s < 4; s++) {
        char nm[48];
        snprintf(nm, sizeof(nm), "randomised batch %d (80 requests)", s);
        b = bnew(nm, s == 0);
        if (s == 0)
            for (i = 0; i < 384; i++) bseed(b, 0x1000u + (uint32_t)i * 3u);
        for (i = 0; i < 80; i++) {
            uint32_t r    = rnd();
            uint32_t pick = r % 100u;
            uint32_t seq  = (r >> 7) % (uint32_t)KVP_NUM_SEQ;
            uint32_t idx  = (r >> 13) % 64u;
            if      (pick < 55u) badd(b, kvp_req(OP_RANGE,   seq, 1u + (r >> 19) % 12u));
            else if (pick < 75u) badd(b, kvp_req(OP_XLATE,   seq, idx));
            else if (pick < 85u) badd(b, kvp_req(OP_NOALLOC, seq, idx));
            else if (pick < 95u) badd(b, kvp_req(OP_FREE,    seq, 1u + (r >> 21) % 16u));
            else                 badd(b, kvp_req(OP_FLUSH,   0,   0));
        }
    }
}

/* ---------------- file writers ---------------- */
static void dump_hex(const char *path, const uint32_t *p, uint32_t n)
{
    FILE *f = fopen(path, "w");
    uint32_t i;
    if (!f) { perror(path); exit(1); }
    for (i = 0; i < n; i++) fprintf(f, "%08x\n", p[i]);
    fclose(f);
}

int main(int argc, char **argv)
{
    const char *outdir = ".";
    char path[512];
    uint32_t i, res_next = KVP_RES_BASE_W;
    kvp_state_t st;
    FILE *f;
    uint32_t prev_x = 0;
    int b;

    for (i = 1; i < (uint32_t)argc; i++) {
        if (!strcmp(argv[i], "--outdir") && i + 1 < (uint32_t)argc) outdir = argv[++i];
        else if (!strcmp(argv[i], "--seed") && i + 1 < (uint32_t)argc)
            rng_s = strtoull(argv[++i], 0, 0) | 1ull;
    }

    /* ---- initial memory: block table invalid, four rows pre-populated ---- */
    memset(MEM, 0, sizeof(MEM));
    for (i = 0; i < (uint32_t)KVP_BT_WORDS; i++) MEM[KVP_BT_BASE_W + i] = KVP_BT_INVALID;
    for (i = 0; i < 4; i++)
        MEM[KVP_BT_BASE_W + 5u * KVP_BT_STRIDE + i] = 0x300u + i;   /* sequence 5 */

    build_workload();

    snprintf(path, sizeof(path), "%s/mem_init.hex", outdir);
    dump_hex(path, MEM, KVP_MEM_WORDS);          /* before the model mutates it */

    /* ---- golden run ---- */
    memset(&st, 0, sizeof(st));
    kvp_soft_reset(&st);
    for (b = 0; b < NB; b++) {
        batch_t *p = &B[b];
        if (p->reset) kvp_soft_reset(&st);
        for (i = 0; i < (uint32_t)p->nfree; i++) kvp_push_free(&st, p->freeblk[i]);
        st.sticky_oom = 0;
        prev_x  = st.xlates;
        p->resw = res_next;
        p->nres = kvp_run_batch(&st, MEM, p->reqw, p->resw, (uint32_t)p->nreq);
        res_next += p->nres;
        p->d_xlates = st.xlates - prev_x;
        p->c_reqs = st.reqs; p->c_xlates = st.xlates; p->c_hits = st.hits;
        p->c_misses = st.misses; p->c_allocs = st.allocs; p->c_frees = st.frees;
        p->c_errs = st.errs; p->c_free = (uint32_t)st.sp;
        p->exp_oom = st.sticky_oom;
        if (res_next > KVP_MEM_WORDS) { fprintf(stderr, "result region overflow\n"); return 1; }
    }

    /* ---- vectors ---- */
    snprintf(path, sizeof(path), "%s/golden_res.hex", outdir);
    dump_hex(path, MEM + KVP_RES_BASE_W, res_next - KVP_RES_BASE_W);
    snprintf(path, sizeof(path), "%s/golden_bt.hex", outdir);
    dump_hex(path, MEM + KVP_BT_BASE_W, KVP_BT_WORDS);

    snprintf(path, sizeof(path), "%s/batches.txt", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    for (b = 0; b < NB; b++) {
        batch_t *p = &B[b];
        fprintf(f, "%d %d %u %u %d %u %u %u %u %u %u %u %u %u %u %d\n",
                p->reset, p->nfree, p->reqw, p->resw, p->nreq, p->nres, p->d_xlates,
                p->c_reqs, p->c_xlates, p->c_hits, p->c_misses, p->c_allocs,
                p->c_frees, p->c_errs, p->c_free, p->exp_oom);
        for (i = 0; i < (uint32_t)p->nfree; i++) fprintf(f, "%08x\n", p->freeblk[i]);
    }
    fclose(f);

    snprintf(path, sizeof(path), "%s/kvp_const.vh", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "// generated by sw/kvp_host - do not edit\n");
    fprintf(f, "`define NUM_BATCH %d\n", NB);
    fprintf(f, "`define TOT_RES %u\n", res_next - KVP_RES_BASE_W);
    fprintf(f, "`define PEAK_BATCH %d\n", peak_batch);
    fprintf(f, "`define LAT_BATCH %d\n", lat_batch);
    fprintf(f, "`define MEM_WORDS %d\n", KVP_MEM_WORDS);
    fprintf(f, "`define BT_WORDS %d\n", KVP_BT_WORDS);
    fprintf(f, "`define BT_BASE_W %d\n", KVP_BT_BASE_W);
    fprintf(f, "`define BT_STRIDE %d\n", KVP_BT_STRIDE);
    fprintf(f, "`define RES_BASE_W %d\n", KVP_RES_BASE_W);
    fprintf(f, "`define CFG_SETS %d\n", KVP_SETS);
    fprintf(f, "`define CFG_WAYS %d\n", KVP_WAYS);
    fprintf(f, "`define CFG_FREE_DEPTH %d\n", KVP_FREE_DEPTH);
    fprintf(f, "`define MAX_FREE_SEED %d\n", KVP_FREE_DEPTH);
    fclose(f);

    /* ---- workload totals + scalar baseline ---- */
    snprintf(path, sizeof(path), "%s/sw_metrics.txt", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    {
        uint64_t t_reqs = 0, t_x = 0, t_h = 0, t_m = 0, t_a = 0, t_fr = 0, base;
        uint32_t peak_x = B[peak_batch].d_xlates;
        for (b = 0; b < NB; b++) {
            /* cumulative counters restart on a reset batch, so re-derive totals
             * from the per-batch deltas of every counter */
            uint32_t p_reqs = 0, p_x = 0, p_h = 0, p_m = 0, p_a = 0, p_f = 0;
            if (b > 0 && !B[b].reset) {
                p_reqs = B[b-1].c_reqs; p_x = B[b-1].c_xlates; p_h = B[b-1].c_hits;
                p_m = B[b-1].c_misses;  p_a = B[b-1].c_allocs; p_f = B[b-1].c_frees;
            }
            t_reqs += B[b].c_reqs - p_reqs;  t_x  += B[b].c_xlates - p_x;
            t_h    += B[b].c_hits - p_h;     t_m  += B[b].c_misses - p_m;
            t_a    += B[b].c_allocs - p_a;   t_fr += B[b].c_frees - p_f;
        }
        base = kvp_baseline_cycles(t_reqs, t_h, t_m, t_a, t_fr);
        fprintf(f, "batches %d\n", NB);
        fprintf(f, "tot_reqs %llu\n",    (unsigned long long)t_reqs);
        fprintf(f, "tot_xlates %llu\n",  (unsigned long long)t_x);
        fprintf(f, "tot_hits %llu\n",    (unsigned long long)t_h);
        fprintf(f, "tot_misses %llu\n",  (unsigned long long)t_m);
        fprintf(f, "tot_allocs %llu\n",  (unsigned long long)t_a);
        fprintf(f, "tot_frees %llu\n",   (unsigned long long)t_fr);
        fprintf(f, "tot_results %u\n",   res_next - KVP_RES_BASE_W);
        fprintf(f, "peak_xlates %u\n",   peak_x);
        fprintf(f, "baseline_cycles %llu\n", (unsigned long long)base);
        fprintf(f, "baseline_peak_cycles %llu\n",
                (unsigned long long)kvp_baseline_cycles(8, peak_x, 0, 0, 0));
        kvp_baseline_terms(f);
        printf("workload: %d batches, %llu request words, %llu translations "
               "(%llu hits / %llu misses / %llu allocs / %llu frees), %u results\n",
               NB, (unsigned long long)t_reqs, (unsigned long long)t_x,
               (unsigned long long)t_h, (unsigned long long)t_m,
               (unsigned long long)t_a, (unsigned long long)t_fr,
               res_next - KVP_RES_BASE_W);
        printf("scalar baseline cost model: %llu cycles\n", (unsigned long long)base);
    }
    fclose(f);
    return 0;
}
