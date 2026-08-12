/* ============================================================================
 * sdv_baseline.c - the software-only verifier this accelerator replaces, plus
 *                  the cost model that turns its work into cycles.
 *
 * This is the loop that runs on the host CPU today, in between the draft model
 * finishing and the target model's next forward pass starting: for every step
 * of the accepted path it has to sweep the whole node list looking for
 * children of the current node, because a draft tree is a pointer structure
 * and there is no index from parent to children.  That is O(nodes x depth)
 * comparisons of pure control flow, and the GPUs are idle for all of it.
 *
 * The cost model charges, per job:
 *
 *   LOAD_CYC   1 cycle per 32-bit word pulled in (4 per node record)
 *   VISIT_CYC  1 cycle per node examined in a path-step sweep (the load of
 *              parent[j] plus the compare against the current node)
 *   CMP_CYC    2 cycles per acceptance predicate actually evaluated (token
 *              compare, threshold compare, mode select, argmax update)
 *   MUL_CYC    3 cycles per relative-threshold multiply
 *   STORE_CYC  1 cycle per result word written back
 *   JOB_CYC    12 cycles of per-job overhead (call, validation setup, return)
 *
 * These are deliberately generous to the CPU - one cycle per examined node is
 * an optimistic figure for a dependent pointer chase - so the reported speedup
 * is a lower bound rather than a flattering one.
 * ==========================================================================*/
#include "sdv.h"

#define LOAD_CYC   1u
#define VISIT_CYC  1u
#define CMP_CYC    2u
#define MUL_CYC    3u
#define STORE_CYC  1u
#define JOB_CYC    12u

static uint16_t bl_thr(uint16_t pmax, uint32_t th_abs, uint32_t th_rel)
{
    uint32_t rel = ((uint32_t)pmax * (th_rel & 0xFFFFu)) >> 16;
    uint32_t abs = th_abs & 0xFFFFu;
    return (uint16_t)(rel > abs ? rel : abs);
}

static int bl_ok(const sdv_node_t *nd, uint32_t mode,
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

int sdv_baseline(const sdv_job_t *job, sdv_beat_t *out, int out_max,
                 sdv_cost_t *cost)
{
    uint32_t n = job->n_nodes, j, cur, acc, cap, flags = 0u, err = SDV_ERR_NONE;
    int nout = 0;

    cost->words_loaded += (uint64_t)n * 4u;
    cost->cycles       += (uint64_t)n * 4u * LOAD_CYC + JOB_CYC;

    /* --- validation: the CPU walks the list once per check ---------------- */
    /* the same fixed priority the hardware priority-encodes: a separate pass
     * per check, so a job that fails several reports the highest-priority one */
    if (n == 0u || n > (uint32_t)SDV_MAX_NODES) {
        err = SDV_ERR_NNODES;
    } else {
        cost->compares += 3u * (uint64_t)(n - 1u) + 1u;
        cost->cycles   += (3u * (uint64_t)(n - 1u) + 1u) * CMP_CYC;
        if ((job->node[0].parent & 0xFFFFu) != SDV_ROOT_PARENT) err = SDV_ERR_ROOT;
        for (j = 1u; j < n && err == SDV_ERR_NONE; j++)
            if ((job->node[j].parent & 0xFFFFu) == SDV_ROOT_PARENT) err = SDV_ERR_ROOT;
        for (j = 1u; j < n && err == SDV_ERR_NONE; j++)
            if ((job->node[j].parent & 0xFFFFu) >= n) err = SDV_ERR_PARENT;
        for (j = 1u; j < n && err == SDV_ERR_NONE; j++)
            if ((job->node[j].parent & 0xFFFFu) == j) err = SDV_ERR_SELF;
    }

    if (err != SDV_ERR_NONE) {
        if (nout < out_max) {
            out[nout].w[0] = 0u;
            out[nout].w[1] = 0u;
            out[nout].w[2] = err;
            out[nout].w[3] = ((n > 0xFFFFu ? 0xFFFFu : n) << 16);
            nout++;
        }
        cost->stores += 4u;
        cost->cycles += 4u * STORE_CYC;
        return nout;
    }

    cap = job->max_acc;
    if (cap > (uint32_t)SDV_MAX_DEPTH) cap = (uint32_t)SDV_MAX_DEPTH;

    cur = 0u;
    acc = 0u;
    for (;;) {
        uint32_t pred_cur = job->node[cur].pred;
        uint16_t thr_cur;
        int      best    = -1;
        uint16_t best_sc = 0u;

        thr_cur       = bl_thr(job->node[cur].pmax, job->th_abs, job->th_rel);
        cost->muls   += 1u;
        cost->cycles += MUL_CYC;

        for (j = 1u; j < n; j++) {
            cost->node_visits += 1u;
            cost->cycles      += VISIT_CYC;
            if ((job->node[j].parent & 0xFFFFu) != cur) continue;
            cost->compares += 1u;
            cost->cycles   += CMP_CYC;
            if (!bl_ok(&job->node[j], job->mode, pred_cur, thr_cur)) continue;
            if (best < 0 || job->node[j].score > best_sc) {
                best    = (int)j;
                best_sc = job->node[j].score;
            }
        }

        if (best < 0) break;
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
        cost->stores += 4u;
        cost->cycles += 4u * STORE_CYC;
    }

    if (nout < out_max) {
        out[nout].w[0] = acc;
        out[nout].w[1] = job->node[cur].pred;
        out[nout].w[2] = SDV_ERR_NONE;
        out[nout].w[3] = ((n > 0xFFFFu ? 0xFFFFu : n) << 16) | flags;
        nout++;
    }
    cost->stores += 4u;
    cost->cycles += 4u * STORE_CYC;
    return nout;
}
