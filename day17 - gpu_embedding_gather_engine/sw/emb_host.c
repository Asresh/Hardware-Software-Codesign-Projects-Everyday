/* emb_host.c - build the device memory image, the descriptor ring and the golden
 * outputs that the RTL testbench is checked against.
 *
 *   ./emb_host --outdir tb/vectors
 *
 * emits
 *   mem_init.hex    device memory image ($readmemh into the testbench slave)
 *   golden_out.hex  expected contents of the output region after the run
 *   emb_const.vh    the geometry + expected statistics, `include`d by the tb
 *   descs.txt       human-readable descriptor listing
 *   sw_metrics.txt  scalar baseline cost model figures
 *
 * The ring is 18 directed descriptors covering every corner of the pooling
 * semantics followed by 300 randomised ones, so a pass checks well past the
 * 256-random-vector bar without any of the directed cases being diluted.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "emb.h"

static uint32_t mem[EMB_MEM_WORDS];
static uint32_t gold[EMB_MEM_WORDS];

static uint32_t rng_s = 0x1BADF00Du;
static uint32_t rnd(void)
{
    rng_s ^= rng_s << 13;
    rng_s ^= rng_s >> 17;
    rng_s ^= rng_s << 5;
    return rng_s;
}
static uint32_t rnd_range(uint32_t lo, uint32_t hi) /* inclusive */
{
    return lo + rnd() % (hi - lo + 1);
}

/* ------------------------------------------------------------- descriptor ring */
static uint32_t n_desc;
static uint32_t idx_cursor;              /* next free word in the index arena */
static char     dnote[EMB_MAX_DESC][96];

/* Append a bag.  idx_off is kept beat-aligned so the index burst is a clean
 * ceil(num_idx/LANES) beats, which is what the RTL assumes. */
static uint32_t add_bag(uint32_t op, const uint32_t *ix, uint32_t n, const char *note)
{
    uint32_t d = n_desc++;
    uint32_t *dw = &mem[EMB_DESC_BASE + d * EMB_DESC_WORDS];

    if (d >= EMB_MAX_DESC) { fprintf(stderr, "descriptor ring overflow\n"); exit(1); }

    uint32_t off = idx_cursor;
    for (uint32_t i = 0; i < n && i < EMB_MAX_BAG; i++)
        mem[EMB_IDX_BASE + off + i] = ix[i];

    /* advance past the bag, rounded up to a whole memory beat */
    uint32_t take = (n > EMB_MAX_BAG) ? EMB_MAX_BAG : n;
    if (take == 0) take = EMB_LANES;
    idx_cursor += ((take + EMB_LANES - 1) / EMB_LANES) * EMB_LANES;
    if (idx_cursor + EMB_MAX_BAG > EMB_IDX_WORDS) {
        fprintf(stderr, "index arena overflow\n"); exit(1);
    }

    dw[0] = op;
    dw[1] = n;
    dw[2] = off;
    dw[3] = d * EMB_DIM;
    dw[4] = dw[5] = dw[6] = dw[7] = 0;

    snprintf(dnote[d], sizeof dnote[d], "%s", note ? note : "random");
    return d;
}

/* ------------------------------------------------------------------ table fill */
static void fill_table(void)
{
    for (uint32_t r = 0; r < EMB_LOCAL_ROWS; r++) {
        uint32_t *row = &mem[EMB_TAB_BASE + r * EMB_DIM];
        for (uint32_t e = 0; e < EMB_DIM; e++) {
            /* moderate magnitudes by default so ordinary bags do not wrap; the
             * planted rows below carry the saturation / wrap cases */
            int32_t v = (int32_t)(rnd() % 2097152u) - 1048576;
            row[e] = (uint32_t)v;
        }
    }
    /* planted rows, addressed by local row number */
    uint32_t *r0 = &mem[EMB_TAB_BASE + 0 * EMB_DIM];
    uint32_t *r1 = &mem[EMB_TAB_BASE + 1 * EMB_DIM];
    uint32_t *r2 = &mem[EMB_TAB_BASE + 2 * EMB_DIM];
    uint32_t *r3 = &mem[EMB_TAB_BASE + 3 * EMB_DIM];
    uint32_t *r4 = &mem[EMB_TAB_BASE + 4 * EMB_DIM];
    uint32_t *r5 = &mem[EMB_TAB_BASE + 5 * EMB_DIM];
    uint32_t *r6 = &mem[EMB_TAB_BASE + 6 * EMB_DIM];
    for (uint32_t e = 0; e < EMB_DIM; e++) {
        r0[e] = 0x7FFFFFFFu;                       /* INT32_MAX        */
        r1[e] = 0x80000000u;                       /* INT32_MIN        */
        r2[e] = 0xFFFFFFFFu;                       /* -1               */
        r3[e] = (e & 1) ? 0x80000000u : 0x7FFFFFFFu;
        r4[e] = 0u;
        r5[e] = 7u;
        r6[e] = (uint32_t)(-7);
    }
}

#define LOCAL(r) (EMB_SHARD_LO + (r))

int main(int argc, char **argv)
{
    const char *outdir = "tb/vectors";
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--outdir") && i + 1 < argc) outdir = argv[++i];

    memset(mem, 0, sizeof mem);
    fill_table();

    /* poison the output region: any word the engine fails to write stays poison
     * in the hardware and in the golden image, so a missed write is a mismatch */
    for (uint32_t w = 0; w < EMB_OUT_WORDS; w++) mem[EMB_OUT_BASE + w] = EMB_POISON;

    /* ------------------------------------------------ directed descriptors */
    uint32_t ix[EMB_MAX_BAG + 4];

    /* 1  empty bag -> zero vector */
    add_bag(EMB_OP_SUM, ix, 0, "empty bag (num_idx=0) -> zero vector");

    /* 2  single local index */
    ix[0] = LOCAL(10);
    add_bag(EMB_OP_SUM, ix, 1, "single local index");

    /* 3  single index owned by a peer shard -> zero vector */
    ix[0] = 0;
    add_bag(EMB_OP_SUM, ix, 1, "single remote index -> zero vector");

    /* 4  every index remote */
    ix[0] = 5; ix[1] = 4095; ix[2] = EMB_SHARD_HI; ix[3] = EMB_SHARD_LO - 1;
    add_bag(EMB_OP_SUM, ix, 4, "all four indices remote -> zero vector");

    /* 5  exactly LANES local indices (one whole index beat) */
    for (uint32_t i = 0; i < EMB_LANES; i++) ix[i] = LOCAL(20 + i);
    add_bag(EMB_OP_SUM, ix, EMB_LANES, "exactly LANES local indices");

    /* 6  MAX over INT32_MIN and -1 -> -1 (all-negative rows) */
    ix[0] = LOCAL(1); ix[1] = LOCAL(2);
    add_bag(EMB_OP_MAX, ix, 2, "MAX over INT32_MIN and -1 -> -1");

    /* 7  MIN over INT32_MAX and -1 -> -1 */
    ix[0] = LOCAL(0); ix[1] = LOCAL(2);
    add_bag(EMB_OP_MIN, ix, 2, "MIN over INT32_MAX and -1 -> -1");

    /* 8  SUM of INT32_MAX twice -> wraps to -2 */
    ix[0] = LOCAL(0); ix[1] = LOCAL(0);
    add_bag(EMB_OP_SUM, ix, 2, "SUM INT32_MAX + INT32_MAX -> two's-complement wrap");

    /* 9  MEAN of -7 and 0 -> -3 (truncation toward zero) */
    ix[0] = LOCAL(6); ix[1] = LOCAL(4);
    add_bag(EMB_OP_MEAN, ix, 2, "MEAN (-7 + 0)/2 -> -3, truncated toward zero");

    /* 10 MEAN of a single row -> divide by 1 */
    ix[0] = LOCAL(6);
    add_bag(EMB_OP_MEAN, ix, 1, "MEAN with count 1 -> divide by one");

    /* 11 MEAN exactly divisible */
    ix[0] = LOCAL(5); ix[1] = LOCAL(5);
    add_bag(EMB_OP_MEAN, ix, 2, "MEAN (7 + 7)/2 -> 7, exact");

    /* 12 the same row five times */
    for (uint32_t i = 0; i < 5; i++) ix[i] = LOCAL(31);
    add_bag(EMB_OP_SUM, ix, 5, "duplicate index five times");

    /* 13 both shard boundaries */
    ix[0] = EMB_SHARD_LO; ix[1] = EMB_SHARD_HI - 1;
    add_bag(EMB_OP_MAX, ix, 2, "first and last row of the shard");

    /* 14 index exactly at shard_hi is remote; one local row survives */
    ix[0] = EMB_SHARD_HI; ix[1] = LOCAL(1);
    add_bag(EMB_OP_MIN, ix, 2, "index == shard_hi is remote, one local row pooled");

    /* 15 MEAN over alternating INT32_MAX / INT32_MIN rows */
    ix[0] = LOCAL(3); ix[1] = LOCAL(3); ix[2] = LOCAL(3);
    add_bag(EMB_OP_MEAN, ix, 3, "MEAN over alternating INT32_MAX / INT32_MIN");

    /* 16 full-depth bag, every index local -> the peak-throughput descriptor */
    for (uint32_t i = 0; i < EMB_MAX_BAG; i++) ix[i] = LOCAL(64 + (i % 128));
    uint32_t peak_desc = add_bag(EMB_OP_SUM, ix, EMB_MAX_BAG,
                                 "MAX_BAG all-local indices (peak descriptor)");

    /* 17 bag longer than the index buffer -> rejected, nothing written */
    for (uint32_t i = 0; i < EMB_MAX_BAG + 1; i++) ix[i] = LOCAL(i % 128);
    add_bag(EMB_OP_SUM, ix, EMB_MAX_BAG + 1, "num_idx > MAX_BAG -> baglen error");

    /* 18 index past the end of the global table -> error, local row still pooled */
    ix[0] = EMB_TABLE_ROWS + 5; ix[1] = LOCAL(11);
    add_bag(EMB_OP_SUM, ix, 2, "index >= table_rows -> index error");

    /* 19 mixture of local, remote and invalid */
    ix[0] = LOCAL(12); ix[1] = 3; ix[2] = EMB_TABLE_ROWS; ix[3] = LOCAL(13);
    add_bag(EMB_OP_MEAN, ix, 4, "local + remote + invalid mixture");

    uint32_t n_directed = n_desc;

    /* ------------------------------------------------ randomised descriptors */
    const uint32_t N_RAND = 300;
    for (uint32_t t = 0; t < N_RAND; t++) {
        uint32_t op = rnd() & 3u;
        uint32_t n  = rnd_range(1, EMB_MAX_BAG);
        for (uint32_t i = 0; i < n; i++) {
            if (rnd() % 100 < 60)
                ix[i] = rnd_range(EMB_SHARD_LO, EMB_SHARD_HI - 1);  /* local  */
            else
                ix[i] = rnd() % EMB_TABLE_ROWS;                     /* either */
        }
        add_bag(op, ix, n, NULL);
    }

    /* --------------------------------------------------------- golden result */
    memcpy(gold, mem, sizeof mem);
    emb_cfg_t cfg = { EMB_SHARD_LO, EMB_SHARD_HI, EMB_TABLE_ROWS };
    emb_stats_t st;
    memset(&st, 0, sizeof st);
    emb_model_run(mem, gold, &cfg, EMB_DESC_BASE, n_desc, EMB_IDX_BASE,
                  EMB_TAB_BASE, EMB_OUT_BASE, &st);

    /* peak descriptor on its own, so the testbench can measure a clean
     * steady-state throughput for one all-local full-depth bag */
    emb_stats_t pst;
    memset(&pst, 0, sizeof pst);
    static uint32_t gold_peak[EMB_MEM_WORDS];
    memcpy(gold_peak, mem, sizeof mem);
    emb_model_run(mem, gold_peak, &cfg, EMB_DESC_BASE + peak_desc * EMB_DESC_WORDS,
                  1, EMB_IDX_BASE, EMB_TAB_BASE, EMB_OUT_BASE, &pst);

    uint64_t ops = 0;
    uint64_t base_cyc = emb_baseline_cycles(mem, &cfg, EMB_DESC_BASE, n_desc,
                                            EMB_IDX_BASE, &ops);
    uint64_t pops = 0;
    uint64_t peak_base = emb_baseline_cycles(mem, &cfg,
                                             EMB_DESC_BASE + peak_desc * EMB_DESC_WORDS,
                                             1, EMB_IDX_BASE, &pops);

    uint32_t mem_used = EMB_OUT_BASE + n_desc * EMB_DIM;

    /* -------------------------------------------------------------- emit */
    char path[512];
    FILE *f;

#define OPEN(name)                                                   \
    snprintf(path, sizeof path, "%s/%s", outdir, name);              \
    f = fopen(path, "w");                                            \
    if (!f) { perror(path); return 1; }

    OPEN("mem_init.hex")
    for (uint32_t w = 0; w < mem_used; w++) fprintf(f, "%08x\n", mem[w]);
    fclose(f);

    OPEN("golden_out.hex")
    for (uint32_t w = 0; w < n_desc * EMB_DIM; w++)
        fprintf(f, "%08x\n", gold[EMB_OUT_BASE + w]);
    fclose(f);

    OPEN("descs.txt")
    for (uint32_t d = 0; d < n_desc; d++) {
        const uint32_t *dw = &mem[EMB_DESC_BASE + d * EMB_DESC_WORDS];
        static const char *opn[4] = { "SUM", "MEAN", "MAX", "MIN" };
        fprintf(f, "%3u op=%-4s n=%-3u idx_off=%-6u dst_off=%-6u %s\n",
                d, opn[dw[0] & 3], dw[1], dw[2], dw[3], dnote[d]);
    }
    fclose(f);

    OPEN("emb_const.vh")
    fprintf(f, "// generated by sw/emb_host.c - do not edit\n");
    fprintf(f, "`define G_DIM %d\n",            EMB_DIM);
    fprintf(f, "`define G_LANES %d\n",          EMB_LANES);
    fprintf(f, "`define G_CHUNKS %d\n",         EMB_CHUNKS);
    fprintf(f, "`define G_MAX_BAG %d\n",        EMB_MAX_BAG);
    fprintf(f, "`define G_MEM_WORDS %d\n",      EMB_MEM_WORDS);
    fprintf(f, "`define G_MEM_USED %u\n",       mem_used);
    fprintf(f, "`define G_DESC_BASE %d\n",      EMB_DESC_BASE);
    fprintf(f, "`define G_DESC_WORDS %d\n",     EMB_DESC_WORDS);
    fprintf(f, "`define G_IDX_BASE %d\n",       EMB_IDX_BASE);
    fprintf(f, "`define G_TAB_BASE %d\n",       EMB_TAB_BASE);
    fprintf(f, "`define G_OUT_BASE %d\n",       EMB_OUT_BASE);
    fprintf(f, "`define G_OUT_WORDS %u\n",      n_desc * EMB_DIM);
    fprintf(f, "`define G_NDESC %u\n",          n_desc);
    fprintf(f, "`define G_NDIRECTED %u\n",      n_directed);
    fprintf(f, "`define G_PEAK_DESC %u\n",      peak_desc);
    fprintf(f, "`define G_SHARD_LO %d\n",       EMB_SHARD_LO);
    fprintf(f, "`define G_SHARD_HI %d\n",       EMB_SHARD_HI);
    fprintf(f, "`define G_TABLE_ROWS %d\n",     EMB_TABLE_ROWS);
    fprintf(f, "`define G_POISON 32'h%08x\n",   EMB_POISON);
    fprintf(f, "`define G_ST_DESC %u\n",        st.desc);
    fprintf(f, "`define G_ST_IDX %u\n",         st.idx);
    fprintf(f, "`define G_ST_LOCAL %u\n",       st.local);
    fprintf(f, "`define G_ST_REMOTE %u\n",      st.remote);
    fprintf(f, "`define G_ST_INVALID %u\n",     st.invalid);
    fprintf(f, "`define G_ST_BAGLEN %u\n",      st.err_baglen);
    fprintf(f, "`define G_ST_RBEATS %u\n",      st.rbeats);
    fprintf(f, "`define G_ST_WBEATS %u\n",      st.wbeats);
    fprintf(f, "`define G_PEAK_LOCAL %u\n",     pst.local);
    fprintf(f, "`define G_PEAK_RBEATS %u\n",    pst.rbeats);
    fprintf(f, "`define G_PEAK_WBEATS %u\n",    pst.wbeats);
    fprintf(f, "`define G_BASE_CYC %llu\n",     (unsigned long long)base_cyc);
    fprintf(f, "`define G_PEAK_BASE_CYC %llu\n",(unsigned long long)peak_base);
    fclose(f);

    OPEN("sw_metrics.txt")
    fprintf(f, "descriptors            %u\n", n_desc);
    fprintf(f, "directed_descriptors   %u\n", n_directed);
    fprintf(f, "random_descriptors     %u\n", N_RAND);
    fprintf(f, "indices                %u\n", st.idx);
    fprintf(f, "local_rows             %u\n", st.local);
    fprintf(f, "remote_indices         %u\n", st.remote);
    fprintf(f, "invalid_indices        %u\n", st.invalid);
    fprintf(f, "baglen_rejects         %u\n", st.err_baglen);
    fprintf(f, "read_beats             %u\n", st.rbeats);
    fprintf(f, "write_beats            %u\n", st.wbeats);
    fprintf(f, "output_words           %u\n", n_desc * EMB_DIM);
    fprintf(f, "baseline_cycles        %llu\n", (unsigned long long)base_cyc);
    fprintf(f, "baseline_ops           %llu\n", (unsigned long long)ops);
    fprintf(f, "peak_local_rows        %u\n", pst.local);
    fprintf(f, "peak_read_beats        %u\n", pst.rbeats);
    fprintf(f, "peak_baseline_cycles   %llu\n", (unsigned long long)peak_base);
    fclose(f);

    printf("emb_host: %u descriptors (%u directed + %u random), %u indices, "
           "%u local rows, %u remote, %u invalid\n",
           n_desc, n_directed, N_RAND, st.idx, st.local, st.remote, st.invalid);
    printf("emb_host: %u read beats, %u write beats, %u output words, "
           "baseline %llu cycles\n",
           st.rbeats, st.wbeats, n_desc * EMB_DIM, (unsigned long long)base_cyc);
    return 0;
}
