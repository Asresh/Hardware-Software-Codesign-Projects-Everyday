/* ===========================================================================
 * kds_driver.c - bare-metal driver for the kernel-DAG scheduler.
 *
 * This is the software half of the co-design: it owns everything that is a
 * policy decision or happens once per graph, and nothing that repeats per
 * scheduling decision.
 *
 *   kds_build_graph()   lays a launch out in shared memory - which kernels,
 *                       which dependencies, which devices each one is allowed
 *                       to run on. Placement *policy* is software; placement
 *                       *mechanics* are hardware.
 *   kds_launch()        points the engine at the graph and rings the doorbell.
 *   kds_isr()           the completion path: one interrupt per graph, W1C.
 *   kds_collect()       reads the per-node schedule back and the CSR counters,
 *                       which is what a runtime needs to rebalance the next
 *                       graph (per-device occupancy, structural versus
 *                       dependency stalls, how much parallelism it actually
 *                       got out of the DAG).
 *
 * Compiled only for the build check in the Makefile - there is no CPU in this
 * simulation - but it is the code that would run on one.
 * ===========================================================================
 */
#include <string.h>
#include "kds.h"

#ifndef KDS_MMIO_BASE
#define KDS_MMIO_BASE 0x40000000u
#endif

#define REG(o) (*(volatile uint32_t *)((uintptr_t)KDS_MMIO_BASE + (o)))

static inline void     kds_wr(uint32_t off, uint32_t v) { REG(off) = v; }
static inline uint32_t kds_rd(uint32_t off)             { return REG(off); }

/* ------------------------------------------------------------------------- */
/* Lay a graph out in shared memory. Returns the number of words written.     */
/* ------------------------------------------------------------------------- */
uint32_t kds_build_graph(volatile uint32_t *node_array,
                         const kds_node_t *nd, uint32_t n)
{
    uint32_t i, w, p = 0;
    for (i = 0; i < n; i++) {
        node_array[p++] = KDS_W0_PACK(nd[i].dur, nd[i].dev);
        for (w = 0; w < (uint32_t)KDS_DEPW; w++) node_array[p++] = nd[i].dep[w];
        node_array[p++] = nd[i].kid;
    }
    return p;
}

/* Convenience: mark "node b must wait for node a". */
void kds_add_edge(kds_node_t *nd, uint32_t a, uint32_t b)
{
    nd[b].dep[a >> 5] |= (1u << (a & 31u));
}

/* ------------------------------------------------------------------------- */
void kds_launch(uint32_t node_base, uint32_t rslt_base, uint32_t n)
{
    kds_wr(KDS_IRQ_STATUS, KDS_IRQ_DONE | KDS_IRQ_ERR);   /* clear stale W1C */
    kds_wr(KDS_IRQ_ENABLE, KDS_IRQ_DONE | KDS_IRQ_ERR);
    kds_wr(KDS_NUM_NODES,  n);
    kds_wr(KDS_NODE_BASE,  node_base);
    kds_wr(KDS_RSLT_BASE,  rslt_base);
    kds_wr(KDS_CTRL,       KDS_CTRL_START);
}

/* Interrupt handler: returns the error code (0 on a clean graph). */
int kds_isr(void)
{
    uint32_t irq = kds_rd(KDS_IRQ_STATUS);
    uint32_t st  = kds_rd(KDS_STATUS);
    kds_wr(KDS_IRQ_STATUS, irq);                          /* write 1 to clear */
    if (irq & KDS_IRQ_ERR) return (int)KDS_ST_ERRC(st);
    return KDS_ERR_NONE;
}

/* Polling alternative for systems without the interrupt wired up. */
int kds_wait(void)
{
    uint32_t st;
    do { st = kds_rd(KDS_STATUS); } while (st & KDS_ST_BUSY);
    return (st & KDS_ST_ERR) ? (int)KDS_ST_ERRC(st) : KDS_ERR_NONE;
}

/* ------------------------------------------------------------------------- */
/* Read the schedule and the counters back.                                  */
/* ------------------------------------------------------------------------- */
void kds_collect(const volatile uint32_t *rslt_array, uint32_t n,
                 kds_result_t *out)
{
    uint32_t i, d;
    memset(out, 0, sizeof *out);
    for (i = 0; i < n && i < (uint32_t)KDS_MAX_NODES; i++) {
        uint32_t w2 = rslt_array[4*i + 2];
        out->start[i]  = rslt_array[4*i + 0];
        out->finish[i] = rslt_array[4*i + 1];
        out->seq[i]    = KDS_R2_SEQ(w2);
        out->dev[i]    = KDS_R2_DEV(w2);
    }
    out->makespan      = kds_rd(KDS_MAKESPAN);
    out->dispatched    = kds_rd(KDS_DISPATCHED);
    out->stall_ticks   = kds_rd(KDS_STALL_TICKS);
    out->depwait_ticks = kds_rd(KDS_DEPWAIT_TICK);
    out->max_conc      = kds_rd(KDS_MAX_CONC);
    out->serial_ticks  = kds_rd(KDS_SERIAL_TICKS);
    for (d = 0; d < (uint32_t)KDS_DEVICES; d++)
        out->dev_busy[d] = kds_rd(KDS_DEV_BUSY(d));
}

/* How much parallelism the engine actually extracted, in hundredths, so the
 * runtime can decide whether to widen the graph or rebalance affinity. */
uint32_t kds_efficiency_x100(const kds_result_t *r)
{
    if (r->makespan == 0) return 0;
    return (r->serial_ticks * 100u) / r->makespan;
}
