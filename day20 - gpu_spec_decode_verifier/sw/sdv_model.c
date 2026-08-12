/* ============================================================================
 * sdv_model.c - bit-exact golden model of the draft-tree verifier.
 *
 * This is the contract the RTL is held to: for a job it produces the exact
 * sequence of egress beats the hardware must emit, and the exact increments
 * the statistics counters must take.  It deliberately mirrors the hardware's
 * order of operations rather than the "obvious" software formulation:
 *
 *   - validation is one pass with a fixed error priority (NNODES > ROOT >
 *     PARENT > SELF), because the hardware evaluates all four checks in
 *     parallel and priority-encodes the result;
 *   - the relative threshold thr(p) = max(TH_ABS, (pmax(p)*TH_REL) >> 16) is
 *     computed once per node when the node is loaded, not once per step, so
 *     the multiplier sits outside the walk loop in both;
 *   - the walk stops when no child of the current node passes, which costs one
 *     extra evaluation - the same extra cycle the hardware spends.
 * ==========================================================================*/
#include <string.h>
#include "sdv.h"

/* thr for a node acting as a parent: the "typical acceptance" floor. */
static uint16_t sdv_thr(uint16_t pmax, uint32_t th_abs, uint32_t th_rel)
{
    uint32_t rel = ((uint32_t)pmax * (th_rel & 0xFFFFu)) >> 16;  /* Q0.16     */
    uint32_t abs = th_abs & 0xFFFFu;
    return (uint16_t)(rel > abs ? rel : abs);
}

static uint32_t sdv_validate(const sdv_job_t *job)
{
    uint32_t n = job->n_nodes, j;

    if (n == 0u || n > (uint32_t)SDV_MAX_NODES) return SDV_ERR_NNODES;

    if ((job->node[0].parent & 0xFFFFu) != SDV_ROOT_PARENT) return SDV_ERR_ROOT;
    for (j = 1u; j < n; j++)
        if ((job->node[j].parent & 0xFFFFu) == SDV_ROOT_PARENT) return SDV_ERR_ROOT;

    for (j = 1u; j < n; j++)
        if ((job->node[j].parent & 0xFFFFu) >= n) return SDV_ERR_PARENT;

    for (j = 1u; j < n; j++)
        if ((job->node[j].parent & 0xFFFFu) == j) return SDV_ERR_SELF;

    return SDV_ERR_NONE;
}

/* the per-node acceptance predicate, given the current parent's broadcast */
static int sdv_ok(const sdv_node_t *nd, uint32_t mode,
                  uint32_t pred_cur, uint16_t thr_cur)
{
    int g = (nd->tok == pred_cur);
    int t = (nd->score >= thr_cur);
    switch (mode & 3u) {
        case SDV_MODE_GREEDY:  return g;
        case SDV_MODE_TYPICAL: return t;
        case SDV_MODE_BOTH:    return g && t;
        default:               return g || t;
    }
}

int sdv_verify(const sdv_job_t *job, sdv_beat_t *out, int out_max,
               sdv_stats_t *st)
{
    uint16_t thr[SDV_MAX_NODES + 8];
    uint32_t err, n, j, cur, acc, cap, flags = 0u, bonus;
    int nout = 0;

    n   = job->n_nodes;
    err = sdv_validate(job);

    /* thresholds are precomputed as the nodes arrive, error or not */
    for (j = 0u; j < n && j < (uint32_t)(SDV_MAX_NODES); j++)
        thr[j] = sdv_thr(job->node[j].pmax, job->th_abs, job->th_rel);

    if (st) {
        st->jobs++;
        st->nodes += n;                       /* every beat the link delivered */
    }

    if (err != SDV_ERR_NONE) {
        if (st) st->errjobs++;
        if (nout < out_max) {
            out[nout].w[0] = 0u;
            out[nout].w[1] = 0u;
            out[nout].w[2] = err;
            out[nout].w[3] = ((n > 0xFFFFu ? 0xFFFFu : n) << 16);
            nout++;
        }
        return nout;
    }

    cap = job->max_acc;
    if (cap > (uint32_t)SDV_MAX_DEPTH) cap = (uint32_t)SDV_MAX_DEPTH;

    cur = 0u;
    acc = 0u;
    for (;;) {
        uint32_t pred_cur = job->node[cur].pred;
        uint16_t thr_cur  = thr[cur];
        int      best     = -1;
        uint16_t best_sc  = 0u;

        for (j = 1u; j < n; j++) {
            if ((job->node[j].parent & 0xFFFFu) != cur) continue;
            if (!sdv_ok(&job->node[j], job->mode, pred_cur, thr_cur)) continue;
            if (best < 0 || job->node[j].score > best_sc) {   /* ties: low idx */
                best    = (int)j;
                best_sc = job->node[j].score;
            }
        }

        if (best < 0) break;                     /* nothing acceptable here   */
        if (acc == cap) { flags |= SDV_FLAG_CLAMP; break; }

        cur = (uint32_t)best;
        acc++;
        if (nout < out_max) {
            out[nout].w[0] = cur;
            out[nout].w[1] = job->node[cur].tok;
            out[nout].w[2] = job->node[cur].score;
            out[nout].w[3] = acc;
            nout++;
        }
        if (st && acc <= (uint32_t)SDV_MAX_DEPTH) st->hist[acc - 1u]++;
    }

    bonus = job->node[cur].pred;

    if (st) {
        st->accept += acc;
        if (flags & SDV_FLAG_CLAMP) st->clamp++;
    }

    if (nout < out_max) {
        out[nout].w[0] = acc;
        out[nout].w[1] = bonus;
        out[nout].w[2] = SDV_ERR_NONE;
        out[nout].w[3] = ((n > 0xFFFFu ? 0xFFFFu : n) << 16) | flags;
        nout++;
    }
    return nout;
}
