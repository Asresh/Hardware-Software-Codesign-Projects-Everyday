/* ============================================================================
 * sdv_host.c - stimulus generator and golden producer for the draft-tree
 *              verifier.
 *
 *   ./sdv_host --nrand N --seed S --outdir DIR
 *
 * Builds a mix of directed corner cases and randomised draft trees, runs each
 * through the golden model (sdv_model.c) and, independently, through the
 * scalar baseline (sdv_baseline.c), and refuses to emit anything if the two
 * disagree - the accelerator is then checked against a result two separate
 * implementations already agree on.  Writes into DIR:
 *
 *   stream.hex     the 128-bit ingress beats, one node record per line
 *   jobs.txt       per job: {mode, th_abs, th_rel, max_acc, beats, out beats}
 *                  followed by the exact egress beats the hardware must emit
 *   totals.txt     the aggregate counters and the per-depth acceptance
 *                  histogram the CSRs must hold at the end of a pass
 *   sdv_const.vh   Verilog parameters for the testbench
 *   sw_metrics.txt scalar-baseline cost-model totals for the metrics report
 *
 * The randomised trees are built parent-before-child and then relabelled
 * through a random permutation that fixes node 0, so index order is
 * deliberately not tree order: nothing in the design may assume a parent has a
 * lower index than its children.
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sdv.h"

/* ---- deterministic PRNG (xorshift64*) ----------------------------------- */
static uint64_t rng_s = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(void)
{
    uint64_t x = rng_s;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    rng_s = x;
    return (uint32_t)((x * 0x2545F4914F6CDD1Dull) >> 32);
}
static uint32_t rnd_below(uint32_t n) { return n ? rnd() % n : 0u; }

#define MAXJOBS   512
#define MAXBEATS  (MAXJOBS * (SDV_MAX_NODES + 8))
#define OUTMAX    (SDV_MAX_DEPTH + 2)

static sdv_job_t  jobs[MAXJOBS];
static sdv_beat_t gold[MAXJOBS][OUTMAX];
static int        ngold[MAXJOBS];
static int        njobs = 0;
static int        peak_job = 0;
static int        min_job  = 0;      /* the root-only job: minimum latency case */

static sdv_job_t *new_job(uint32_t mode, uint32_t th_abs, uint32_t th_rel,
                          uint32_t max_acc)
{
    sdv_job_t *j = &jobs[njobs++];
    memset(j, 0, sizeof(*j));
    j->mode = mode; j->th_abs = th_abs; j->th_rel = th_rel;
    j->max_acc = max_acc;
    return j;
}

static void set_node(sdv_job_t *j, uint32_t i, uint32_t parent, uint32_t tok,
                     uint32_t pred, uint32_t score, uint32_t pmax)
{
    j->node[i].parent = parent;
    j->node[i].tok    = tok;
    j->node[i].pred   = pred;
    j->node[i].score  = (uint16_t)score;
    j->node[i].pmax   = (uint16_t)pmax;
    if (i + 1u > j->n_nodes) j->n_nodes = i + 1u;
}

/* ------------------------------------------------------------------------ */
/* directed corner cases                                                     */
/* ------------------------------------------------------------------------ */

/* a straight chain of `len` nodes (root + len-1 children) that all match in
 * greedy mode; `sc` is the score every child carries. */
static sdv_job_t *chain(uint32_t len, uint32_t mode, uint32_t max_acc,
                        uint32_t sc, uint32_t pmax)
{
    sdv_job_t *j = new_job(mode, 0u, 0u, max_acc);
    uint32_t i;
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 100u, 0u, pmax);
    for (i = 1u; i < len; i++)
        set_node(j, i, i - 1u, 100u + i - 1u, 100u + i, sc, pmax);
    return j;
}

static void build_directed(void)
{
    sdv_job_t *j;
    uint32_t i;

    /* 0: peak - a MAX_NODES-node chain, every link matching.  This is the
     *    throughput micro-benchmark: MAX_NODES beats in, MAX_DEPTH accepted. */
    peak_job = njobs;
    chain((uint32_t)SDV_MAX_NODES, SDV_MODE_GREEDY, (uint32_t)SDV_MAX_DEPTH,
          0x8000u, 0xFFFFu);

    /* 1: root only - nothing to accept, bonus token is the root's pred.  Also
     *    the shortest possible job, so it is the latency micro-benchmark. */
    min_job = njobs;
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 4242u, 0u, 0x4000u);

    /* 2: chain of exactly MAX_DEPTH accepted tokens, no clamp */
    chain((uint32_t)SDV_MAX_DEPTH + 1u, SDV_MODE_GREEDY,
          (uint32_t)SDV_MAX_DEPTH, 0x1000u, 0x2000u);

    /* 3: chain one longer than the cap - must clamp and flag it */
    chain((uint32_t)SDV_MAX_DEPTH + 2u, SDV_MODE_GREEDY,
          (uint32_t)SDV_MAX_DEPTH, 0x1000u, 0x2000u);

    /* 4: MAX_ACC = 1 - accept one token then stop with the clamp flag */
    chain(8u, SDV_MODE_GREEDY, 1u, 0x1000u, 0x2000u);

    /* 5: MAX_ACC = 0 - accept nothing, still emit a trailer with the bonus */
    chain(8u, SDV_MODE_GREEDY, 0u, 0x1000u, 0x2000u);

    /* 6: MAX_ACC above MAX_DEPTH - hardware must clamp the cap itself */
    chain((uint32_t)SDV_MAX_DEPTH + 4u, SDV_MODE_GREEDY,
          (uint32_t)SDV_MAX_DEPTH + 99u, 0x1000u, 0x2000u);

    /* 7: nothing matches at all */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 7u, 0u, 0x8000u);
    for (i = 1u; i < 8u; i++) set_node(j, i, 0u, 1000u + i, 9u, 0x9000u, 0x9000u);

    /* 8: wide fan-out from the root, exactly one child matching */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 55u, 0u, 0x8000u);
    for (i = 1u; i < (uint32_t)SDV_MAX_NODES; i++)
        set_node(j, i, 0u, (i == 13u) ? 55u : (200u + i), 77u,
                 0x1000u + i, 0x8000u);

    /* 9: two children tie on score - the lower index must win */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 31u, 0u, 0x8000u);
    set_node(j, 1, 0u, 31u, 41u, 0x4000u, 0x8000u);
    set_node(j, 2, 0u, 31u, 51u, 0x4000u, 0x8000u);
    set_node(j, 3, 0u, 31u, 61u, 0x4000u, 0x8000u);

    /* 10: highest score wins even though it is the last index */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 31u, 0u, 0x8000u);
    set_node(j, 1, 0u, 31u, 41u, 0x4000u, 0x8000u);
    set_node(j, 2, 0u, 31u, 51u, 0x4001u, 0x8000u);
    set_node(j, 3, 0u, 31u, 61u, 0xFFFFu, 0x8000u);

    /* 11: typical mode, score exactly on the threshold - >= must accept */
    j = new_job(SDV_MODE_TYPICAL, 0x2000u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 12u, 0u, 0x8000u);
    set_node(j, 1, 0u, 900u, 13u, 0x2000u, 0x8000u);

    /* 12: typical mode, one below the threshold - must reject */
    j = new_job(SDV_MODE_TYPICAL, 0x2000u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 12u, 0u, 0x8000u);
    set_node(j, 1, 0u, 900u, 13u, 0x1FFFu, 0x8000u);

    /* 13: relative threshold dominates the absolute one
     *     thr = max(0x0100, (0x8000 * 0x8000)>>16 = 0x4000) = 0x4000        */
    j = new_job(SDV_MODE_TYPICAL, 0x0100u, 0x8000u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 12u, 0u, 0x8000u);
    set_node(j, 1, 0u, 900u, 13u, 0x4000u, 0x8000u);  /* accepted            */
    set_node(j, 2, 0u, 901u, 14u, 0x3FFFu, 0x8000u);  /* rejected            */

    /* 14: pmax = 0 - the relative term vanishes, TH_ABS governs */
    j = new_job(SDV_MODE_TYPICAL, 0x0800u, 0xFFFFu, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 12u, 0u, 0u);
    set_node(j, 1, 0u, 900u, 13u, 0x0800u, 0u);

    /* 15: TH_ABS = 0 and TH_REL = 0 - everything passes the typical test */
    j = new_job(SDV_MODE_TYPICAL, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 12u, 0u, 0xFFFFu);
    set_node(j, 1, 0u, 900u, 13u, 0u, 0xFFFFu);
    set_node(j, 2, 1u, 901u, 14u, 0u, 0xFFFFu);

    /* 16: saturated probabilities - pmax and TH_REL both 0xFFFF */
    j = new_job(SDV_MODE_TYPICAL, 0u, 0xFFFFu, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 12u, 0u, 0xFFFFu);
    set_node(j, 1, 0u, 900u, 13u, 0xFFFFu, 0xFFFFu);  /* thr = 0xFFFE       */
    set_node(j, 2, 0u, 901u, 14u, 0xFFFDu, 0xFFFFu);

    /* 17: BOTH - greedy passes but the score does not */
    j = new_job(SDV_MODE_BOTH, 0x4000u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 88u, 0u, 0x8000u);
    set_node(j, 1, 0u, 88u, 89u, 0x0100u, 0x8000u);

    /* 18: ANY - greedy fails but the score passes */
    j = new_job(SDV_MODE_ANY, 0x4000u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 88u, 0u, 0x8000u);
    set_node(j, 1, 0u, 7777u, 89u, 0x8000u, 0x8000u);

    /* 19: BOTH - a branch where only the child passing both tests survives */
    j = new_job(SDV_MODE_BOTH, 0x4000u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 88u, 0u, 0x8000u);
    set_node(j, 1, 0u, 88u,   89u, 0x3FFFu, 0x8000u);   /* score too low     */
    set_node(j, 2, 0u, 7777u, 90u, 0xF000u, 0x8000u);   /* token wrong       */
    set_node(j, 3, 0u, 88u,   91u, 0x4000u, 0x8000u);   /* accepted          */

    /* 20: reverse labelling - every parent has a HIGHER index than its child */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    {
        uint32_t len = 8u;
        /* node 0 stays the root; the chain runs 0 <- len-1 <- len-2 <- ... */
        set_node(j, 0, SDV_ROOT_PARENT, 0u, 300u, 0u, 0x8000u);
        for (i = 1u; i < len; i++) {
            uint32_t idx = len - i;              /* len-1, len-2, ... 1      */
            uint32_t par = (i == 1u) ? 0u : (len - i + 1u);
            set_node(j, idx, par, 300u + i - 1u, 300u + i, 0x2000u, 0x8000u);
        }
    }

    /* 21: an unreachable 2-cycle beside a live chain - inert, not an error */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 500u, 0u, 0x8000u);
    set_node(j, 1, 0u, 500u, 501u, 0x3000u, 0x8000u);
    set_node(j, 2, 1u, 501u, 502u, 0x3000u, 0x8000u);
    set_node(j, 3, 4u, 500u, 900u, 0xF000u, 0x8000u);   /* 3 <-> 4 cycle     */
    set_node(j, 4, 3u, 500u, 901u, 0xF000u, 0x8000u);

    /* 22: duplicate tokens among siblings, distinguished only by score */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 61u, 0u, 0x8000u);
    for (i = 1u; i < 6u; i++) set_node(j, i, 0u, 61u, 62u, 0x1000u * i, 0x8000u);
    for (i = 6u; i < 9u; i++) set_node(j, i, 5u, 62u, 63u, 0x2000u, 0x8000u);

    /* 23: deep chain that runs out of tree before it runs out of cap */
    chain(4u, SDV_MODE_GREEDY, (uint32_t)SDV_MAX_DEPTH, 0x0001u, 0x0001u);

    /* --- rejection cases ------------------------------------------------- */

    /* 24: too many nodes */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 1u, 0u, 0x8000u);
    for (i = 1u; i < (uint32_t)SDV_MAX_NODES + 3u; i++)
        set_node(j, i, i - 1u, 1u, 1u, 0x1000u, 0x8000u);

    /* 25: node 0 is not a root */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, 1u, 0u, 1u, 0u, 0x8000u);
    set_node(j, 1, 0u, 1u, 2u, 0x1000u, 0x8000u);

    /* 26: a second root */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 1u, 0u, 0x8000u);
    set_node(j, 1, 0u, 1u, 2u, 0x1000u, 0x8000u);
    set_node(j, 2, SDV_ROOT_PARENT, 1u, 3u, 0x1000u, 0x8000u);

    /* 27: dangling parent index */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 1u, 0u, 0x8000u);
    set_node(j, 1, 0u, 1u, 2u, 0x1000u, 0x8000u);
    set_node(j, 2, 9u, 2u, 3u, 0x1000u, 0x8000u);

    /* 28: a self edge */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 1u, 0u, 0x8000u);
    set_node(j, 1, 0u, 1u, 2u, 0x1000u, 0x8000u);
    set_node(j, 2, 2u, 2u, 3u, 0x1000u, 0x8000u);

    /* 29: three checks fail at once - ROOT must win the priority encode */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 1u, 0u, 0x8000u);
    set_node(j, 1, SDV_ROOT_PARENT, 1u, 2u, 0x1000u, 0x8000u); /* second root */
    set_node(j, 2, 40u, 2u, 3u, 0x1000u, 0x8000u);             /* dangling    */
    set_node(j, 3, 3u,  3u, 4u, 0x1000u, 0x8000u);             /* self edge   */

    /* 30: dangling and self both present - PARENT outranks SELF */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 1u, 0u, 0x8000u);
    set_node(j, 1, 1u,  1u, 2u, 0x1000u, 0x8000u);             /* self edge   */
    set_node(j, 2, 40u, 2u, 3u, 0x1000u, 0x8000u);             /* dangling    */

    /* 31: exactly one node past the array - the tightest overflow case there
     *     is, and the one a >= / > slip in the detector would let through */
    j = new_job(SDV_MODE_GREEDY, 0u, 0u, (uint32_t)SDV_MAX_DEPTH);
    set_node(j, 0, SDV_ROOT_PARENT, 0u, 1u, 0u, 0x8000u);
    for (i = 1u; i < (uint32_t)SDV_MAX_NODES + 1u; i++)
        set_node(j, i, i - 1u, 1u, 1u, 0x1000u, 0x8000u);

    /* 32: a good job right after the bad ones - the engine must recover */
    chain(6u, SDV_MODE_GREEDY, (uint32_t)SDV_MAX_DEPTH, 0x2000u, 0x8000u);
}

/* ------------------------------------------------------------------------ */
/* randomised trees                                                          */
/* ------------------------------------------------------------------------ */
static void build_random(int count)
{
    int t;
    for (t = 0; t < count; t++) {
        uint32_t n     = 2u + rnd_below((uint32_t)SDV_MAX_NODES - 1u);
        uint32_t mode  = rnd_below(4u);
        uint32_t vocab = 4u + rnd_below(8u);
        uint32_t th_abs, th_rel, max_acc;
        uint32_t par[SDV_MAX_NODES], tok[SDV_MAX_NODES], pred[SDV_MAX_NODES];
        uint32_t sc[SDV_MAX_NODES], pm[SDV_MAX_NODES];
        uint32_t perm[SDV_MAX_NODES], inv[SDV_MAX_NODES];
        uint32_t i, k;
        sdv_job_t *j;

        /* keep a healthy spread of accept lengths across the whole run */
        switch (rnd_below(4u)) {
            case 0:  th_abs = 0u;              th_rel = 0u;              break;
            case 1:  th_abs = rnd() & 0x3FFFu; th_rel = 0u;              break;
            case 2:  th_abs = 0u;              th_rel = rnd() & 0xFFFFu; break;
            default: th_abs = rnd() & 0x7FFFu; th_rel = rnd() & 0xFFFFu; break;
        }
        max_acc = rnd_below((uint32_t)SDV_MAX_DEPTH + 3u);

        /* build parent-before-child, biased towards deep trees */
        pred[0] = rnd_below(vocab);
        par[0]  = SDV_ROOT_PARENT;
        tok[0]  = 0u;
        sc[0]   = 0u;
        pm[0]   = rnd() & 0xFFFFu;
        for (i = 1u; i < n; i++) {
            uint32_t p = (rnd_below(100u) < 60u) ? (i - 1u) : rnd_below(i);
            par[i]  = p;
            pred[i] = rnd_below(vocab);
            pm[i]   = rnd() & 0xFFFFu;
            sc[i]   = rnd() & 0xFFFFu;
            /* a draft model is right more often than not */
            tok[i]  = (rnd_below(100u) < 55u) ? pred[p] : rnd_below(vocab);
        }

        /* relabel 1..n-1 with a random permutation; node 0 stays the root */
        for (i = 0u; i < n; i++) perm[i] = i;
        for (i = n - 1u; i >= 1u; i--) {
            uint32_t r = 1u + rnd_below(i);      /* r in [1, i]              */
            uint32_t tmp = perm[i]; perm[i] = perm[r]; perm[r] = tmp;
        }
        for (i = 0u; i < n; i++) inv[perm[i]] = i;   /* old i -> new inv[i]  */

        j = new_job(mode, th_abs, th_rel, max_acc);
        for (i = 0u; i < n; i++) {
            k = perm[i];                              /* new slot i holds k  */
            set_node(j, i, (k == 0u) ? SDV_ROOT_PARENT : inv[par[k]],
                     tok[k], pred[k], sc[k], pm[k]);
        }
    }
}

/* ------------------------------------------------------------------------ */
int main(int argc, char **argv)
{
    const char *outdir = "tb/vectors";
    int nrand = 300, i, b;
    uint64_t seed = 0x5DEC0DE202008ull;
    sdv_stats_t st;
    sdv_cost_t  cost, peak_cost;
    FILE *fs, *fj, *ft, *fc, *fm;
    char path[512];
    uint64_t total_beats = 0, total_out = 0, hw_cycles_model = 0;
    uint64_t peak_hw_cycles = 0;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--outdir") && i + 1 < argc)     outdir = argv[++i];
        else if (!strcmp(argv[i], "--nrand") && i + 1 < argc) nrand = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc)
            seed = strtoull(argv[++i], NULL, 0);
    }
    rng_s = seed ? seed : 1ull;

    build_directed();
    {
        int ndirected = njobs;
        if (nrand > MAXJOBS - ndirected) nrand = MAXJOBS - ndirected;
        build_random(nrand);

        memset(&st, 0, sizeof(st));
        memset(&cost, 0, sizeof(cost));

        for (i = 0; i < njobs; i++) {
            sdv_beat_t bl[OUTMAX];
            int nb;
            ngold[i] = sdv_verify(&jobs[i], gold[i], OUTMAX, &st);
            nb = sdv_baseline(&jobs[i], bl, OUTMAX, &cost);
            if (nb != ngold[i]) {
                fprintf(stderr, "job %d: model/baseline beat count %d vs %d\n",
                        i, ngold[i], nb);
                return 1;
            }
            for (b = 0; b < nb; b++) {
                int w;
                for (w = 0; w < 4; w++)
                    if (bl[b].w[w] != gold[i][b].w[w]) {
                        fprintf(stderr, "job %d beat %d word %d: model %08x "
                                "baseline %08x\n", i, b, w,
                                gold[i][b].w[w], bl[b].w[w]);
                        return 1;
                    }
            }
            total_beats += jobs[i].n_nodes;
            total_out   += (uint64_t)ngold[i];
            /* the hardware's own cycle count for this job, for the report:
             * load + check + walk(accept+1) + trailer */
            hw_cycles_model += jobs[i].n_nodes + 1u + (uint64_t)ngold[i] + 1u;
        }

        /* the peak job costed on its own, so the report can quote a per-job
         * speedup that is not diluted by the short randomised trees */
        {
            sdv_beat_t pk[OUTMAX];
            memset(&peak_cost, 0, sizeof(peak_cost));
            (void)sdv_baseline(&jobs[peak_job], pk, OUTMAX, &peak_cost);
            peak_hw_cycles = jobs[peak_job].n_nodes + 1u
                           + (uint64_t)ngold[peak_job] + 1u;
        }

        /* -------- stream.hex -------------------------------------------- */
        snprintf(path, sizeof(path), "%s/stream.hex", outdir);
        fs = fopen(path, "w");
        if (!fs) { perror(path); return 1; }
        for (i = 0; i < njobs; i++) {
            uint32_t k;
            for (k = 0; k < jobs[i].n_nodes; k++) {
                const sdv_node_t *nd = &jobs[i].node[k];
                fprintf(fs, "%08x%08x%08x%08x\n",
                        ((uint32_t)nd->pmax << 16) | (uint32_t)nd->score,
                        nd->pred, nd->tok, nd->parent & 0xFFFFu);
            }
        }
        fclose(fs);

        /* -------- jobs.txt ---------------------------------------------- */
        snprintf(path, sizeof(path), "%s/jobs.txt", outdir);
        fj = fopen(path, "w");
        if (!fj) { perror(path); return 1; }
        for (i = 0; i < njobs; i++) {
            fprintf(fj, "%u %u %u %u %u %d\n", jobs[i].mode, jobs[i].th_abs,
                    jobs[i].th_rel, jobs[i].max_acc, jobs[i].n_nodes, ngold[i]);
            for (b = 0; b < ngold[i]; b++)
                fprintf(fj, "%08x %08x %08x %08x\n", gold[i][b].w[0],
                        gold[i][b].w[1], gold[i][b].w[2], gold[i][b].w[3]);
        }
        fclose(fj);

        /* -------- totals.txt -------------------------------------------- */
        snprintf(path, sizeof(path), "%s/totals.txt", outdir);
        ft = fopen(path, "w");
        if (!ft) { perror(path); return 1; }
        fprintf(ft, "%u %u %u %u %u\n", st.jobs, st.nodes, st.accept,
                st.errjobs, st.clamp);
        for (i = 0; i < SDV_MAX_DEPTH; i++) fprintf(ft, "%u\n", st.hist[i]);
        fclose(ft);

        /* -------- sdv_const.vh ------------------------------------------ */
        snprintf(path, sizeof(path), "%s/sdv_const.vh", outdir);
        fc = fopen(path, "w");
        if (!fc) { perror(path); return 1; }
        fprintf(fc, "// auto-generated by sdv_host - do not edit\n");
        fprintf(fc, "`define CFG_MAX_NODES %d\n", SDV_MAX_NODES);
        fprintf(fc, "`define CFG_MAX_DEPTH %d\n", SDV_MAX_DEPTH);
        fprintf(fc, "`define NUM_JOBS %d\n", njobs);
        fprintf(fc, "`define NUM_DIRECTED %d\n", ndirected);
        fprintf(fc, "`define NUM_BEATS %llu\n", (unsigned long long)total_beats);
        fprintf(fc, "`define MAX_OUT %d\n", OUTMAX);
        fprintf(fc, "`define PEAK_JOB %d\n", peak_job);
        fprintf(fc, "`define MIN_JOB %d\n", min_job);
        fprintf(fc, "`define REGMAP_CSUM 32'h%08x\n", (unsigned)SDV_REGMAP_CSUM);
        fprintf(fc, "`define SEED 64'h%016llx\n", (unsigned long long)seed);
        fclose(fc);

        /* -------- sw_metrics.txt ---------------------------------------- */
        snprintf(path, sizeof(path), "%s/sw_metrics.txt", outdir);
        fm = fopen(path, "w");
        if (!fm) { perror(path); return 1; }
        fprintf(fm, "jobs %d\n", njobs);
        fprintf(fm, "directed %d\n", ndirected);
        fprintf(fm, "random %d\n", nrand);
        fprintf(fm, "nodes %llu\n", (unsigned long long)total_beats);
        fprintf(fm, "out_beats %llu\n", (unsigned long long)total_out);
        fprintf(fm, "accepted %u\n", st.accept);
        fprintf(fm, "errjobs %u\n", st.errjobs);
        fprintf(fm, "clamped %u\n", st.clamp);
        fprintf(fm, "baseline_cycles %llu\n", (unsigned long long)cost.cycles);
        fprintf(fm, "baseline_words %llu\n", (unsigned long long)cost.words_loaded);
        fprintf(fm, "baseline_visits %llu\n", (unsigned long long)cost.node_visits);
        fprintf(fm, "baseline_compares %llu\n", (unsigned long long)cost.compares);
        fprintf(fm, "baseline_muls %llu\n", (unsigned long long)cost.muls);
        fprintf(fm, "baseline_stores %llu\n", (unsigned long long)cost.stores);
        fprintf(fm, "hw_cycles_model %llu\n", (unsigned long long)hw_cycles_model);
        fprintf(fm, "peak_nodes %u\n", jobs[peak_job].n_nodes);
        fprintf(fm, "peak_out_beats %d\n", ngold[peak_job]);
        fprintf(fm, "peak_baseline_cycles %llu\n",
                (unsigned long long)peak_cost.cycles);
        fprintf(fm, "peak_baseline_visits %llu\n",
                (unsigned long long)peak_cost.node_visits);
        fprintf(fm, "peak_hw_cycles %llu\n", (unsigned long long)peak_hw_cycles);
        fclose(fm);

        printf("sdv_host: %d jobs (%d directed, %d random), %llu beats, "
               "%u accepted tokens, %u rejected, %u clamped\n",
               njobs, ndirected, nrand, (unsigned long long)total_beats,
               st.accept, st.errjobs, st.clamp);
    }
    return 0;
}
