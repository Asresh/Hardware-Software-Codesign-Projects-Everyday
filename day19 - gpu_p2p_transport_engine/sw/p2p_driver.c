/* ===========================================================================
 * p2p_driver.c - bare-metal firmware for the transport engine.
 *
 * This is the code that would sit in the control processor of an inference
 * node.  It never touches payload: it builds the work-queue ring, points the
 * engine at it, rings the doorbell, and afterwards reads back the counters and
 * decides what to do about them.
 *
 * The interesting part is the last function.  A transport that only says
 * "done" is not much use to a runtime; what a runtime needs to know is *which*
 * resource ran out.  Credit stall cycles mean the peer is short of receive
 * buffers and the fix is to post more of them; link stall cycles mean the wire
 * is saturated and no amount of software will help; memory stall cycles mean
 * the engine is fighting the compute kernels for bandwidth.  Those three are
 * counted separately in hardware precisely so this decision can be made
 * without instrumenting anything.
 * ===========================================================================
 */
#include "p2p.h"

static inline void wr(volatile uint32_t *csr, uint32_t off, uint32_t v)
{
    csr[off >> 2] = v;
}

static inline uint32_t rd(volatile uint32_t *csr, uint32_t off)
{
    return csr[off >> 2];
}

/* ---- build one work-queue entry in shared memory ------------------------ */
void p2p_post_wqe(uint32_t *ring, uint32_t slot, const p2p_wqe_t *w)
{
    uint32_t *e = ring + slot * P2P_WQE_WORDS;
    e[0] = (w->opcode & 0xFu) | ((w->qp & 0xFu) << 4);
    e[1] = w->src;
    e[2] = w->dst;
    e[3] = w->len;
    e[4] = w->tag & 0xFFu;
    e[5] = 0;
    e[6] = 0;
    e[7] = 0;
}

/* ---- point the engine at the ring and ring the doorbell ----------------- */
void p2p_driver_launch(volatile uint32_t *csr, const p2p_run_t *r)
{
    wr(csr, P2P_IRQ_STAT,   P2P_IRQ_DONE | P2P_IRQ_ERR);   /* W1C stale bits */
    wr(csr, P2P_WQ_BASE,    r->wq_base);
    wr(csr, P2P_WQ_COUNT,   r->wq_count);
    wr(csr, P2P_CQ_BASE,    r->cq_base);
    wr(csr, P2P_MEM_LIMIT,  r->mem_limit);
    wr(csr, P2P_CREDIT_LIM, r->credit_lim);
    wr(csr, P2P_INJECT,     r->inject);
    wr(csr, P2P_IRQ_EN,     P2P_IRQ_DONE | P2P_IRQ_ERR);
    wr(csr, P2P_CTRL,       P2P_CTRL_START);
}

/* ---- interrupt service: acknowledge and report ------------------------- */
int p2p_driver_wait(volatile uint32_t *csr)
{
    uint32_t st;

    while ((rd(csr, P2P_IRQ_STAT) & P2P_IRQ_DONE) == 0u)
        ;                                   /* the ISR would sleep here */

    st = rd(csr, P2P_STATUS);
    wr(csr, P2P_IRQ_STAT, P2P_IRQ_DONE | P2P_IRQ_ERR);   /* write-1-to-clear */

    return (st & P2P_STATUS_ERR) ? -(int)rd(csr, P2P_ERR_CODE) : 0;
}

/* ---- drain the completion ring ----------------------------------------- */
uint32_t p2p_driver_reap(const uint32_t *cq, uint32_t n, uint32_t *bytes_out)
{
    uint32_t i, total = 0, ok = 0;

    for (i = 0; i < n; i++) {
        const uint32_t *e = cq + i * P2P_CQE_WORDS;
        if ((e[0] & 0xFFu) == 0u) ok++;
        total += e[2];
    }
    if (bytes_out) *bytes_out = total;
    return ok;
}

/* ---- what the runtime should change before the next collective --------- */
/* Returns 0 if the link is healthy, 1 if the peer needs more receive
 * buffers, 2 if the wire is the limit, 3 if memory bandwidth is the limit. */
int p2p_driver_advise(volatile uint32_t *csr)
{
    uint32_t cyc = rd(csr, P2P_ST_CYCLES);
    uint32_t cr  = rd(csr, P2P_ST_CRSTALL);
    uint32_t lk  = rd(csr, P2P_ST_LKSTALL);
    uint32_t mem = rd(csr, P2P_ST_MEMSTALL);

    if (cyc == 0u) return 0;
    if (cr > cyc / 8u && cr >= lk && cr >= mem) return 1;
    if (lk > cyc / 8u && lk >= mem)             return 2;
    if (mem > cyc / 8u)                          return 3;
    return 0;
}
