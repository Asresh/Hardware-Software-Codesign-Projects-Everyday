/* ===========================================================================
 * kds_host.c - test-vector generator, golden-model driver and metrics writer.
 *
 * Emits, into --outdir:
 *   mem_init.hex   initial contents of the simulated shared memory: every
 *                  graph's node array, and result regions filled with a poison
 *                  pattern
 *   golden_mem.hex the memory as it must look when the last graph retires -
 *                  result regions filled in, everything else untouched, so the
 *                  testbench can prove the engine writes nowhere else
 *   graphs.txt     one line per launch: name, node count, base addresses and
 *                  every value the CSRs must report
 *   kds_const.vh   geometry + counts for the testbench
 *   sw_metrics.txt cost-model baseline totals
 * ===========================================================================
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kds.h"

#define MEM_WORDS_MAX 400000
#define MAX_GRAPHS    512
#define POISON        0xA5A5A5A5u
#define FILLER        0x5A5A5A5Au

typedef struct {
    char       name[24];
    uint32_t   n_cfg;                 /* value written to NUM_NODES          */
    int        n;                     /* records actually laid out in memory */
    kds_node_t nd[KDS_MAX_NODES];
    uint32_t   node_base, rslt_base, rslt_words;
    kds_result_t res;
    kds_base_t   base;
    int          err;
} graph_t;

static uint32_t mem_init[MEM_WORDS_MAX];
static uint32_t mem_gold[MEM_WORDS_MAX];
static graph_t  gr[MAX_GRAPHS];
static int      ngr = 0;
static uint32_t cursor = 0;           /* word cursor into the memory image   */

/* ------------------------------------------------------------------- rng */
static uint32_t rs = 0x1234abcdu;
static uint32_t rnd(void)
{
    rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5;
    return rs;
}
static uint32_t rnd_range(uint32_t lo, uint32_t hi) /* inclusive */
{
    return lo + rnd() % (hi - lo + 1u);
}

/* --------------------------------------------------------------- helpers */
static graph_t *new_graph(const char *name)
{
    graph_t *g = &gr[ngr++];
    memset(g, 0, sizeof *g);
    snprintf(g->name, sizeof g->name, "%s", name);
    return g;
}

static void dep_set(kds_node_t *nd, int j) { nd->dep[j >> 5] |= (1u << (j & 31)); }

static const uint8_t DEV_ALL = (KDS_DEVICES >= 8) ? 0xffu
                                                  : (uint8_t)((1u << KDS_DEVICES) - 1u);

/* ------------------------------------------------- directed graph shapes */
static void mk_single(graph_t *g)
{
    g->n = 1; g->n_cfg = 1;
    g->nd[0].dur = 1; g->nd[0].dev = DEV_ALL; g->nd[0].kid = 0xC0DE0001u;
}

static void mk_chain(graph_t *g, int n, int dur, uint8_t dev)
{
    int i;
    g->n = n; g->n_cfg = (uint32_t)n;
    for (i = 0; i < n; i++) {
        g->nd[i].dur = (uint16_t)dur;
        g->nd[i].dev = dev;
        g->nd[i].kid = 0xC1A10000u + (uint32_t)i;
        if (i) dep_set(&g->nd[i], i - 1);
    }
}

static void mk_indep(graph_t *g, int n, int dur, uint8_t dev)
{
    int i;
    g->n = n; g->n_cfg = (uint32_t)n;
    for (i = 0; i < n; i++) {
        g->nd[i].dur = (uint16_t)dur;
        g->nd[i].dev = dev;
        g->nd[i].kid = 0xC2A20000u + (uint32_t)i;
    }
}

static void mk_layers(graph_t *g, int layers, int width, int dur)
{
    int l, w, i = 0, prev0 = 0, prevn = 0;
    g->n = layers * width; g->n_cfg = (uint32_t)g->n;
    for (l = 0; l < layers; l++) {
        int this0 = i;
        for (w = 0; w < width; w++, i++) {
            int k;
            g->nd[i].dur = (uint16_t)(dur + w);
            g->nd[i].dev = DEV_ALL;
            g->nd[i].kid = 0xC3A30000u + (uint32_t)i;
            for (k = prev0; k < prev0 + prevn; k++) dep_set(&g->nd[i], k);
        }
        prev0 = this0; prevn = width;
    }
}

/* a random DAG, generated in topological order and then relabelled with a
 * random permutation so that node index order is NOT topological order */
static void mk_random(graph_t *g, int n, int maxdur, int p_pct)
{
    int perm[KDS_MAX_NODES];
    int topo_dep[KDS_MAX_NODES][KDS_MAX_NODES];
    int ndep[KDS_MAX_NODES];
    int i, j, k;

    g->n = n; g->n_cfg = (uint32_t)n;

    for (i = 0; i < n; i++) perm[i] = i;
    for (i = n - 1; i > 0; i--) {                 /* Fisher-Yates            */
        j = (int)(rnd() % (uint32_t)(i + 1));
        k = perm[i]; perm[i] = perm[j]; perm[j] = k;
    }

    for (i = 0; i < n; i++) {
        ndep[i] = 0;
        for (j = 0; j < i; j++)
            if ((int)(rnd() % 100u) < p_pct) topo_dep[i][ndep[i]++] = j;
        /* every node past the first layer gets at least one real predecessor
         * some of the time, so the graphs are not all trivially parallel */
        if (i > 0 && ndep[i] == 0 && (rnd() & 1u))
            topo_dep[i][ndep[i]++] = (int)(rnd() % (uint32_t)i);
    }

    for (i = 0; i < n; i++) {
        int t = perm[i];
        g->nd[t].dur = (uint16_t)rnd_range(1, (uint32_t)maxdur);
        do { g->nd[t].dev = (uint8_t)(rnd() & DEV_ALL); } while (g->nd[t].dev == 0);
        g->nd[t].kid = 0xD0000000u | ((uint32_t)ngr << 8) | (uint32_t)t;
        for (j = 0; j < ndep[i]; j++) dep_set(&g->nd[t], perm[topo_dep[i][j]]);
    }
}

/* ------------------------------------------------------- memory placement */
static void place(graph_t *g)
{
    int i, w;
    uint32_t p;

    g->node_base = cursor * 4u;
    for (i = 0; i < g->n; i++) {
        mem_init[cursor++] = KDS_W0_PACK(g->nd[i].dur, g->nd[i].dev);
        for (w = 0; w < KDS_DEPW; w++) mem_init[cursor++] = g->nd[i].dep[w];
        mem_init[cursor++] = g->nd[i].kid;
    }

    g->rslt_words = (uint32_t)(g->n > 0 ? g->n * KDS_RSLT_WORDS : KDS_RSLT_WORDS);
    g->rslt_base  = cursor * 4u;
    for (p = 0; p < g->rslt_words; p++) mem_init[cursor++] = POISON;

    cursor += 2;                                  /* guard words between graphs */
}

static void fill_golden(graph_t *g)
{
    int i;
    uint32_t b = g->rslt_base / 4u;
    if (g->err != KDS_ERR_NONE) return;           /* no writeback on error   */
    for (i = 0; i < g->n; i++) {
        mem_gold[b + 4*i + 0] = g->res.start[i];
        mem_gold[b + 4*i + 1] = g->res.finish[i];
        mem_gold[b + 4*i + 2] = KDS_R2_PACK(g->res.seq[i], g->res.dev[i],
                                            KDS_FLAG_EXEC);
        mem_gold[b + 4*i + 3] = g->nd[i].kid;
    }
}

/* -------------------------------------------------------------------- main */
int main(int argc, char **argv)
{
    const char *outdir = ".";
    char path[512];
    FILE *f;
    int i, k, a;
    uint64_t tot_nodes = 0, tot_ticks = 0, tot_serial = 0, tot_disp = 0;
    uint64_t tot_stall = 0, tot_depwait = 0, tot_base = 0, tot_fetchw = 0;
    uint64_t tot_wbw = 0, tot_ops_scan = 0, tot_ops_poll = 0, tot_ops_launch = 0;
    uint64_t tot_ops_load = 0, tot_idle = 0;
    int peak_idx = -1, nerr = 0;

    for (a = 1; a < argc; a++)
        if (!strcmp(argv[a], "--outdir") && a + 1 < argc) outdir = argv[++a];

    for (i = 0; i < MEM_WORDS_MAX; i++) mem_init[i] = FILLER;

    /* ------------------------------------------------ directed corner cases */
    mk_single(new_graph("single_node"));
    mk_chain (new_graph("chain8_serial"),        8, 3, DEV_ALL);
    mk_indep (new_graph("indep8_parallel"),      8, 5, DEV_ALL);

    {   /* diamond: 0 -> {1,2,3} -> 4 */
        graph_t *g = new_graph("diamond");
        g->n = 5; g->n_cfg = 5;
        for (i = 0; i < 5; i++) {
            g->nd[i].dur = (uint16_t)(2 + i);
            g->nd[i].dev = DEV_ALL;
            g->nd[i].kid = 0xD1A00000u + (uint32_t)i;
        }
        dep_set(&g->nd[1], 0); dep_set(&g->nd[2], 0); dep_set(&g->nd[3], 0);
        dep_set(&g->nd[4], 1); dep_set(&g->nd[4], 2); dep_set(&g->nd[4], 3);
    }

    mk_indep(new_graph("indep8_pin_dev0"), 8, 4, 0x1);   /* affinity serialises */

    {   /* two independent chains, each pinned to its own device */
        graph_t *g = new_graph("two_pinned_chains");
        g->n = 12; g->n_cfg = 12;
        for (i = 0; i < 12; i++) {
            int half = i / 6;
            g->nd[i].dur = 3;
            g->nd[i].dev = (uint8_t)(half ? 0x2 : 0x1);
            g->nd[i].kid = 0xD2A00000u + (uint32_t)i;
            if (i % 6) dep_set(&g->nd[i], i - 1);
        }
    }

    mk_chain(new_graph("chain_max_depth"), KDS_MAX_NODES, 1, DEV_ALL);
    peak_idx = ngr;                                  /* the peak-throughput run */
    mk_indep(new_graph("indep_max_peak"), KDS_MAX_NODES, 1, DEV_ALL);
    mk_indep(new_graph("indep_max_dur16"), KDS_MAX_NODES, 16, DEV_ALL);

    {   /* one very long kernel next to a crowd of short ones */
        graph_t *g = new_graph("one_long_kernel");
        g->n = 10; g->n_cfg = 10;
        for (i = 0; i < 10; i++) {
            g->nd[i].dur = (uint16_t)(i == 0 ? 1000 : 2);
            g->nd[i].dev = DEV_ALL;
            g->nd[i].kid = 0xD3A00000u + (uint32_t)i;
        }
    }

    {   /* fan-in: 32 producers into one consumer (an all-reduce shaped join) */
        graph_t *g = new_graph("fanin32");
        int m = (KDS_MAX_NODES < 33) ? KDS_MAX_NODES - 1 : 32;
        g->n = m + 1; g->n_cfg = (uint32_t)g->n;
        for (i = 0; i < g->n; i++) {
            g->nd[i].dur = (uint16_t)(i == m ? 7 : 3);
            g->nd[i].dev = DEV_ALL;
            g->nd[i].kid = 0xD4A00000u + (uint32_t)i;
        }
        for (i = 0; i < m; i++) dep_set(&g->nd[m], i);
    }

    {   /* fan-out from a single root */
        graph_t *g = new_graph("fanout_root");
        g->n = KDS_MAX_NODES; g->n_cfg = (uint32_t)g->n;
        for (i = 0; i < g->n; i++) {
            g->nd[i].dur = (uint16_t)(i ? 2 : 5);
            g->nd[i].dev = DEV_ALL;
            g->nd[i].kid = 0xD5A00000u + (uint32_t)i;
            if (i) dep_set(&g->nd[i], 0);
        }
    }

    {   /* every node pinned to the highest device only */
        graph_t *g = new_graph("pin_last_device");
        g->n = 6; g->n_cfg = 6;
        for (i = 0; i < 6; i++) {
            g->nd[i].dur = 2;
            g->nd[i].dev = (uint8_t)(1u << (KDS_DEVICES - 1));
            g->nd[i].kid = 0xD6A00000u + (uint32_t)i;
        }
    }

    {   /* reverse topological labelling: node 0 waits on the last node */
        graph_t *g = new_graph("reverse_labels");
        g->n = 8; g->n_cfg = 8;
        for (i = 0; i < 8; i++) {
            g->nd[i].dur = (uint16_t)(1 + (i & 3));
            g->nd[i].dev = DEV_ALL;
            g->nd[i].kid = 0xD7A00000u + (uint32_t)i;
            if (i > 0) dep_set(&g->nd[i - 1], i);   /* i depends on i+1 ... */
        }
    }

    mk_layers(new_graph("layers4x4"), 4, 4, 2);
    mk_layers(new_graph("layers8x2"), 8, 2, 3);

    {   /* mixed affinity: half the graph can go anywhere, half is pinned */
        graph_t *g = new_graph("mixed_affinity");
        g->n = 24; g->n_cfg = 24;
        for (i = 0; i < 24; i++) {
            g->nd[i].dur = (uint16_t)(1 + (i % 5));
            g->nd[i].dev = (uint8_t)((i & 1) ? DEV_ALL
                                             : (1u << (i % KDS_DEVICES)));
            g->nd[i].kid = 0xD8A00000u + (uint32_t)i;
            if (i >= 4) dep_set(&g->nd[i], i - 4);
        }
    }

    /* ------------------------------------------------ directed error cases */
    { graph_t *g = new_graph("err_zero_duration");
      mk_indep(g, 4, 3, DEV_ALL); g->nd[2].dur = 0; }

    { graph_t *g = new_graph("err_empty_affinity");
      mk_indep(g, 4, 3, DEV_ALL); g->nd[1].dev = 0; }

    { graph_t *g = new_graph("err_absent_device");
      mk_indep(g, 4, 3, DEV_ALL);
      g->nd[3].dev = (uint8_t)(1u << KDS_DEVICES); }   /* device that does not exist */

    { graph_t *g = new_graph("err_dep_out_of_range");
      mk_indep(g, 4, 3, DEV_ALL); dep_set(&g->nd[0], 4); }

    { graph_t *g = new_graph("err_self_dep");
      mk_indep(g, 4, 3, DEV_ALL); dep_set(&g->nd[2], 2); }

    { graph_t *g = new_graph("err_cycle2");
      mk_indep(g, 4, 3, DEV_ALL);
      dep_set(&g->nd[1], 2); dep_set(&g->nd[2], 1); }

    { graph_t *g = new_graph("err_cycle3_with_valid");
      mk_indep(g, 8, 2, DEV_ALL);
      dep_set(&g->nd[5], 6); dep_set(&g->nd[6], 7); dep_set(&g->nd[7], 5); }

    { graph_t *g = new_graph("err_num_nodes_zero");
      g->n = 0; g->n_cfg = 0; }

    { graph_t *g = new_graph("err_num_nodes_over");
      g->n = 0; g->n_cfg = KDS_MAX_NODES + 1; }

    /* ------------------------------------------------------ randomised set */
    for (k = 0; k < 300; k++) {
        char nm[24];
        int n = (int)rnd_range(1, KDS_MAX_NODES);
        int maxdur = (k % 7 == 0) ? 64 : 20;
        int p = (int)rnd_range(4, 22);
        snprintf(nm, sizeof nm, "rand%03d", k);
        mk_random(new_graph(nm), n, maxdur, p);
    }

    /* --------------------------------- golden model + placement + baseline */
    for (i = 0; i < ngr; i++) {
        graph_t *g = &gr[i];
        place(g);
        g->err = kds_model(g->nd, (int)g->n_cfg, &g->res);
        if (g->err == KDS_ERR_NONE) {
            kds_baseline(g->nd, g->n, &g->base);
            tot_nodes      += (uint64_t)g->n;
            tot_ticks      += g->res.makespan;
            tot_serial     += g->res.serial_ticks;
            tot_disp       += g->res.dispatched;
            tot_stall      += g->res.stall_ticks;
            tot_depwait    += g->res.depwait_ticks;
            tot_wbw        += (uint64_t)g->n * KDS_RSLT_WORDS;
            tot_base       += g->base.cycles;
            tot_ops_scan   += g->base.ops_scan;
            tot_ops_poll   += g->base.ops_poll;
            tot_ops_launch += g->base.ops_launch;
            tot_ops_load   += g->base.ops_load;
            tot_idle       += g->base.idle_dev_ticks;
        } else {
            nerr++;
        }
        tot_fetchw += (uint64_t)g->n * KDS_NODE_WORDS;
    }

    memcpy(mem_gold, mem_init, sizeof mem_gold);
    for (i = 0; i < ngr; i++) fill_golden(&gr[i]);

    if (cursor >= MEM_WORDS_MAX) {
        fprintf(stderr, "memory image overflow: %u words\n", cursor);
        return 1;
    }

    /* ------------------------------------------------------------- emit ---- */
    snprintf(path, sizeof path, "%s/mem_init.hex", outdir);
    f = fopen(path, "w"); if (!f) { perror(path); return 1; }
    for (i = 0; i < (int)cursor; i++) fprintf(f, "%08x\n", mem_init[i]);
    fclose(f);

    snprintf(path, sizeof path, "%s/golden_mem.hex", outdir);
    f = fopen(path, "w"); if (!f) { perror(path); return 1; }
    for (i = 0; i < (int)cursor; i++) fprintf(f, "%08x\n", mem_gold[i]);
    fclose(f);

    snprintf(path, sizeof path, "%s/graphs.txt", outdir);
    f = fopen(path, "w"); if (!f) { perror(path); return 1; }
    for (i = 0; i < ngr; i++) {
        graph_t *g = &gr[i];
        fprintf(f, "%s %u %d %u %u %d %u %u %u %u %u %u",
                g->name, g->n_cfg, g->n, g->node_base, g->rslt_base,
                g->err, g->res.makespan, g->res.dispatched, g->res.stall_ticks,
                g->res.depwait_ticks, g->res.max_conc, g->res.serial_ticks);
        for (k = 0; k < KDS_DEVICES; k++) fprintf(f, " %u", g->res.dev_busy[k]);
        fprintf(f, "\n");
    }
    fclose(f);

    snprintf(path, sizeof path, "%s/kds_const.vh", outdir);
    f = fopen(path, "w"); if (!f) { perror(path); return 1; }
    fprintf(f, "// generated by sw/kds_host.c - do not edit\n");
    fprintf(f, "`define KDS_TB_MAX_NODES %d\n", KDS_MAX_NODES);
    fprintf(f, "`define KDS_TB_DEVICES   %d\n", KDS_DEVICES);
    fprintf(f, "`define KDS_TB_NODE_WORDS %d\n", KDS_NODE_WORDS);
    fprintf(f, "`define KDS_TB_NGRAPHS   %d\n", ngr);
    fprintf(f, "`define KDS_TB_MEMW      %u\n", cursor);
    fprintf(f, "`define KDS_TB_PEAK_IDX  %d\n", peak_idx);
    fclose(f);

    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir);
    f = fopen(path, "w"); if (!f) { perror(path); return 1; }
    fprintf(f, "graphs %d\n", ngr);
    fprintf(f, "error_graphs %d\n", nerr);
    fprintf(f, "nodes %llu\n", (unsigned long long)tot_nodes);
    fprintf(f, "model_makespan %llu\n", (unsigned long long)tot_ticks);
    fprintf(f, "model_serial %llu\n", (unsigned long long)tot_serial);
    fprintf(f, "model_dispatched %llu\n", (unsigned long long)tot_disp);
    fprintf(f, "model_stall %llu\n", (unsigned long long)tot_stall);
    fprintf(f, "model_depwait %llu\n", (unsigned long long)tot_depwait);
    fprintf(f, "fetch_words %llu\n", (unsigned long long)tot_fetchw);
    fprintf(f, "wb_words %llu\n", (unsigned long long)tot_wbw);
    fprintf(f, "baseline_cycles %llu\n", (unsigned long long)tot_base);
    fprintf(f, "baseline_ops_scan %llu\n", (unsigned long long)tot_ops_scan);
    fprintf(f, "baseline_ops_poll %llu\n", (unsigned long long)tot_ops_poll);
    fprintf(f, "baseline_ops_launch %llu\n", (unsigned long long)tot_ops_launch);
    fprintf(f, "baseline_ops_load %llu\n", (unsigned long long)tot_ops_load);
    fprintf(f, "baseline_idle_dev_ticks %llu\n", (unsigned long long)tot_idle);
    fprintf(f, "peak_idx %d\n", peak_idx);
    fprintf(f, "peak_nodes %d\n", gr[peak_idx].n);
    fprintf(f, "peak_makespan %u\n", gr[peak_idx].res.makespan);
    fprintf(f, "peak_serial %u\n", gr[peak_idx].res.serial_ticks);
    fprintf(f, "peak_baseline_cycles %u\n", gr[peak_idx].base.cycles);
    fprintf(f, "cost_load %u\n", (unsigned)KDS_C_LOAD);
    fprintf(f, "cost_scan_node %u\n", (unsigned)KDS_C_SCAN_NODE);
    fprintf(f, "cost_poll_dev %u\n", (unsigned)KDS_C_POLL_DEV);
    fprintf(f, "cost_launch %u\n", (unsigned)KDS_C_LAUNCH);
    fclose(f);

    printf("kds_host: %d graphs (%d error cases), %llu nodes, memory %u words\n",
           ngr, nerr, (unsigned long long)tot_nodes, cursor);
    printf("          model makespan %llu ticks, serial %llu ticks, baseline %llu cycles\n",
           (unsigned long long)tot_ticks, (unsigned long long)tot_serial,
           (unsigned long long)tot_base);
    return 0;
}
