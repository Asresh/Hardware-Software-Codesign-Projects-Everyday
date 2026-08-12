/* ============================================================================
 * sdv_driver.c - bare-metal firmware for the draft-tree verifier.
 *
 * This is the code that would run on the control processor of an inference
 * node, once per speculative-decoding step.  It is deliberately short, and
 * that is the point of the whole day: the host's entire involvement in
 * verification is four register writes before the draft device streams its
 * tree in, and one pass over the returned beats afterwards.  It never walks a
 * parent pointer, never sweeps the node list, and never evaluates an
 * acceptance predicate - all of which are what the software-only version in
 * sdv_baseline.c spends its cycles on while both GPUs sit idle.
 *
 * The ordering matters and is the reason the thresholds are separate registers
 * from CTRL: the engine latches mode, TH_ABS, TH_REL and MAX_ACC on the *first
 * ingress beat* of a job, not on a doorbell.  So the firmware programs the
 * next step's acceptance policy while the previous step's tokens are still
 * draining out of the egress FIFO, and the draft device's first beat is what
 * commits it.  There is no doorbell write in the steady-state path at all.
 *
 * The last function is the one a serving runtime actually calls every few
 * hundred steps.  A verifier that only reports "N tokens accepted" tells you
 * nothing you can act on; the per-position histogram does.  If HIST[k] falls
 * off a cliff after position 3 then the draft tree is being built four levels
 * deep for nothing, and the fix is to spend that draft compute on width
 * instead - a decision the hardware has already measured for free on the
 * datapath, rather than one the host has to instrument its own loop to find.
 * ==========================================================================*/
#include "sdv.h"

static inline void wr(volatile uint32_t *csr, uint32_t off, uint32_t v)
{
    csr[off >> 2] = v;
}

static inline uint32_t rd(volatile uint32_t *csr, uint32_t off)
{
    return csr[off >> 2];
}

/* ---- one-time bring-up: identify the engine and clear stale state -------- */
int sdv_driver_probe(volatile uint32_t *csr, uint32_t *max_nodes,
                     uint32_t *max_depth)
{
    uint32_t caps;

    if (rd(csr, SDV_REG_VERSION) != SDV_VERSION)      return -1;
    if (rd(csr, SDV_REG_REGMAP_CSUM) != SDV_REGMAP_CSUM) return -2;

    caps = rd(csr, SDV_REG_CAPS);
    if (max_nodes) *max_nodes = caps & 0xFFFFu;
    if (max_depth) *max_depth = (caps >> 16) & 0xFFu;

    wr(csr, SDV_REG_CTRL, SDV_CTRL_SOFT_RST);            /* self-clearing    */
    wr(csr, SDV_REG_IRQ_STAT, SDV_IRQ_DONE | SDV_IRQ_ERROR | SDV_IRQ_CLAMP);
    wr(csr, SDV_REG_CTRL, SDV_CTRL_EN | SDV_CTRL_CLR_STAT);
    return 0;
}

/* ---- program the acceptance policy for the next verification step --------
 * Safe to call while the previous step is still draining: nothing here is
 * sampled until the draft device puts its first node record on the link.
 * ------------------------------------------------------------------------*/
void sdv_driver_arm(volatile uint32_t *csr, uint32_t mode, uint32_t th_abs,
                    uint32_t th_rel, uint32_t max_acc)
{
    wr(csr, SDV_REG_TH_ABS,  th_abs & 0xFFFFu);
    wr(csr, SDV_REG_TH_REL,  th_rel & 0xFFFFu);
    wr(csr, SDV_REG_MAX_ACC, max_acc);
    wr(csr, SDV_REG_CTRL,    SDV_CTRL_EN | SDV_CTRL_IRQ_EN |
                             ((mode << SDV_CTRL_MODE_SH) & SDV_CTRL_MODE_MSK));
}

/* ---- completion: consume the egress beats the engine produced ------------
 * The trailer beat carries TLAST, so the reader frames a step without being
 * told in advance how many tokens were accepted.  Returns the accepted count,
 * or -(error code) if the engine rejected the tree.  `tokens` receives the
 * accepted token ids in path order and `nodes` the node indices, which are
 * what the caller needs to know which KV-cache rows to keep and which to drop.
 * ------------------------------------------------------------------------*/
int sdv_driver_complete(volatile uint32_t *csr, const sdv_beat_t *beats,
                        int nbeats, uint32_t *tokens, uint32_t *nodes,
                        uint32_t *bonus, uint32_t *flags)
{
    const sdv_beat_t *trailer;
    int i, acc;

    if (nbeats < 1) return -1;
    trailer = &beats[nbeats - 1];

    if (trailer->w[2] != SDV_ERR_NONE) {
        wr(csr, SDV_REG_IRQ_STAT, SDV_IRQ_DONE | SDV_IRQ_ERROR);
        wr(csr, SDV_REG_ERRCODE, 0u);                    /* clear the latch  */
        return -(int)trailer->w[2];
    }

    acc = nbeats - 1;                                    /* the rest is data */
    for (i = 0; i < acc; i++) {
        if (nodes)  nodes[i]  = beats[i].w[0];
        if (tokens) tokens[i] = beats[i].w[1];
    }
    if (bonus) *bonus = trailer->w[1];                   /* target's own next */
    if (flags) *flags = trailer->w[3] & 0xFFFFu;

    wr(csr, SDV_REG_IRQ_STAT, SDV_IRQ_DONE | SDV_IRQ_CLAMP);
    return acc;
}

/* ---- telemetry: turn the counters into a draft-policy recommendation -----
 * Returns the depth beyond which fewer than one step in eight is still being
 * accepted, which is the depth the draft tree should be truncated to.  A
 * return of `depth_max` means the tree is paying for itself all the way down
 * and should be made deeper, not shallower.
 * ------------------------------------------------------------------------*/
uint32_t sdv_driver_advise_depth(volatile uint32_t *csr, uint32_t depth_max,
                                 uint32_t *accept_per_1k, uint32_t *clamp_pct)
{
    uint32_t jobs, accept, clamp, k, useful = 0u;

    jobs   = rd(csr, SDV_REG_ST_JOBS);
    accept = rd(csr, SDV_REG_ST_ACCEPT);
    clamp  = rd(csr, SDV_REG_ST_CLAMP);

    if (jobs == 0u) return depth_max;

    if (accept_per_1k) *accept_per_1k = (accept * 1000u) / jobs;
    if (clamp_pct)     *clamp_pct     = (clamp  *  100u) / jobs;

    for (k = 0u; k < depth_max; k++) {
        uint32_t h = rd(csr, SDV_REG_HIST_BASE + k * 4u);
        if (h * 8u < jobs) break;            /* accepted < 1 step in 8 here  */
        useful = k + 1u;
    }
    return useful;
}

/* ---- where did the cycles go --------------------------------------------
 * Three counters, three different actions.  Source-stall cycles mean the draft
 * device is not keeping the link fed and the verifier is waiting on it;
 * backpressure cycles mean whatever consumes the accepted tokens is the
 * bottleneck; the remainder is the engine doing real work.  Returned as
 * per-mille of busy cycles so the caller does not have to divide.
 * ------------------------------------------------------------------------*/
void sdv_driver_stalls(volatile uint32_t *csr, uint32_t *src_pm,
                       uint32_t *bp_pm, uint32_t *busy_out)
{
    uint32_t busy = rd(csr, SDV_REG_ST_BUSY);
    uint32_t src  = rd(csr, SDV_REG_ST_SRCSTALL);
    uint32_t bp   = rd(csr, SDV_REG_ST_BPSTALL);

    if (busy_out) *busy_out = busy;
    if (busy == 0u) busy = 1u;
    if (src_pm) *src_pm = (uint32_t)(((uint64_t)src * 1000u) / busy);
    if (bp_pm)  *bp_pm  = (uint32_t)(((uint64_t)bp  * 1000u) / busy);
}
