/* ============================================================================
 * kvp_driver.c - bare-metal firmware that drives the KV-cache paging engine.
 *
 * This is the software half of the co-design.  The serving runtime keeps the
 * policy - which sequence is admitted, how long its context is, when it is
 * evicted - and hands the engine a batch of requests in shared memory; the
 * engine owns the per-block work: translate, walk, allocate, release.
 *
 * The register sequence below is exactly what tb/kvp_tb.sv performs on the DUT,
 * and the Makefile compiles this file as a standalone build check.
 * ==========================================================================*/
#include "kvp.h"

#ifndef KVP_MMIO_BASE
#define KVP_MMIO_BASE 0xA0020000u
#endif

static volatile uint32_t *const REG = (volatile uint32_t *)(uintptr_t)KVP_MMIO_BASE;

static inline void     reg_wr(int i, uint32_t v) { REG[i] = v; }
static inline uint32_t reg_rd(int i)             { return REG[i]; }

/* ---- one-time setup: where the block table lives, how wide a row is ---- */
void kvp_configure(uint32_t bt_base_bytes, uint32_t bt_stride_words)
{
    reg_wr(R_CTRL, CTRL_SRST);                 /* flush cache, drop the pool */
    reg_wr(R_BT_BASE,   bt_base_bytes);
    reg_wr(R_BT_STRIDE, bt_stride_words);
}

/* ---- seed the physical-block pool; blocks come back out LIFO ---- */
void kvp_seed_pool(const uint32_t *blocks, uint32_t n)
{
    uint32_t i;
    for (i = 0; i < n; i++)
        reg_wr(R_FREE_PUSH, blocks[i]);
}

/* ---- submit one batch of request words and wait for the interrupt ---- */
uint32_t kvp_run(uint32_t req_base_bytes, uint32_t res_base_bytes, uint32_t nreq)
{
    uint32_t st;

    reg_wr(R_REQ_BASE,  req_base_bytes);
    reg_wr(R_RES_BASE,  res_base_bytes);
    reg_wr(R_REQ_COUNT, nreq);
    reg_wr(R_CTRL, CTRL_START | CTRL_IRQEN);

    do { st = reg_rd(R_STATUS); } while ((st & ST_DONE) == 0u);   /* or WFI */

    if (st & ST_OOM) {
        /* the KV cache is full: the runtime must evict a sequence before the
         * next batch - free its blocks with OP_FREE and retry. */
    }
    if (st & ST_BUS) {
        /* block-table address faulted or the interconnect hung */
    }

    reg_wr(R_IRQ_ACK, ST_DONE | ST_OOM | ST_BUS);                 /* W1C */
    return reg_rd(R_RES_WORDS);
}

/* ---- release a sequence's blocks: one OP_FREE request word ---- */
uint32_t kvp_free_sequence(uint32_t *reqs, uint32_t seq, uint32_t nblocks)
{
    reqs[0] = kvp_req(OP_FREE, seq, nblocks);
    return 1;
}

/* ---- paging statistics for the runtime's scheduler ---- */
void kvp_read_stats(uint32_t *out7)
{
    out7[0] = reg_rd(R_STAT_REQS);
    out7[1] = reg_rd(R_STAT_XLATES);
    out7[2] = reg_rd(R_STAT_HITS);
    out7[3] = reg_rd(R_STAT_MISSES);
    out7[4] = reg_rd(R_STAT_ALLOCS);
    out7[5] = reg_rd(R_STAT_FREES);
    out7[6] = reg_rd(R_FREE_COUNT);
}
