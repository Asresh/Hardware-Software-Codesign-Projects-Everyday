/* emb_driver.c - the firmware half of the co-design.
 *
 * This is the code that would run on the host core of the node: it lays out the
 * descriptor ring for a batch of sparse features, tells the engine which slice of
 * the global embedding table this device owns, kicks it off, and services the
 * completion interrupt.  Everything per-index - the shard classification, the
 * gather, the pooling, the divide - is the engine's job; the CPU only ever
 * touches descriptors and status words, which is the point of the split.
 *
 * Built as a compile check by `make sw`; it is not linked into the host tool
 * because it targets the device's register window rather than a POSIX process.
 */
#include "emb.h"

#define MMIO_BASE 0x40000000u

static volatile uint32_t *const csr = (volatile uint32_t *)(uintptr_t)MMIO_BASE;

static inline void wr(uint32_t off, uint32_t v) { csr[off >> 2] = v; }
static inline uint32_t rd(uint32_t off) { return csr[off >> 2]; }

/* ------------------------------------------------------------------ ring build */
/* Pack a batch of sparse features into the descriptor ring.  `bags` is a list of
 * (index-pointer, length) pairs in the caller's arena; `pool` is one of
 * EMB_OP_*.  Returns the number of descriptors written. */
uint32_t emb_build_ring(uint32_t *mem, uint32_t desc_base, uint32_t idx_base,
                        const uint32_t *const *bag_ix, const uint32_t *bag_len,
                        const uint32_t *bag_op, uint32_t n_bags)
{
    uint32_t cursor = 0;

    for (uint32_t b = 0; b < n_bags; b++) {
        uint32_t *dw = &mem[desc_base + b * EMB_DESC_WORDS];
        uint32_t n = bag_len[b];

        /* the engine fetches a bag as one burst of ceil(n / LANES) beats, so
         * every bag starts on a memory-beat boundary */
        for (uint32_t i = 0; i < n; i++)
            mem[idx_base + cursor + i] = bag_ix[b][i];

        dw[0] = bag_op[b];
        dw[1] = n;
        dw[2] = cursor;
        dw[3] = b * EMB_DIM;
        dw[4] = dw[5] = dw[6] = dw[7] = 0;

        uint32_t take = n ? n : EMB_LANES;
        cursor += ((take + EMB_LANES - 1) / EMB_LANES) * EMB_LANES;
    }
    return n_bags;
}

/* ------------------------------------------------------------------- one batch */
int emb_run_batch(uint32_t desc_base, uint32_t desc_count, uint32_t idx_base,
                  uint32_t tab_base, uint32_t out_base, uint32_t shard_lo,
                  uint32_t shard_hi, uint32_t table_rows, emb_stats_t *st)
{
    /* device identification, so the firmware can refuse a mismatched bitstream */
    uint32_t id = rd(EMB_REG_ID);
    if ((id & 0xFFFF0000u) != EMB_ID_MAGIC) return -1;
    if ((id & 0xFFu) != EMB_LANES) return -1;
    if (((id >> 8) & 0xFFu) != EMB_CHUNKS) return -1;

    wr(EMB_REG_DESC_BASE,  desc_base);
    wr(EMB_REG_DESC_COUNT, desc_count);
    wr(EMB_REG_IDX_BASE,   idx_base);
    wr(EMB_REG_TAB_BASE,   tab_base);
    wr(EMB_REG_OUT_BASE,   out_base);
    wr(EMB_REG_SHARD_LO,   shard_lo);
    wr(EMB_REG_SHARD_HI,   shard_hi);
    wr(EMB_REG_TABLE_ROWS, table_rows);

    /* clear the statistics window and arm the completion interrupt */
    wr(EMB_REG_CTRL, EMB_CTRL_CLR_STATS | EMB_CTRL_IRQ_EN);
    wr(EMB_REG_CTRL, EMB_CTRL_START | EMB_CTRL_IRQ_EN);

    /* a real driver sleeps on the interrupt here; polling STATUS.DONE is the
     * fallback path and is what the bring-up sequence uses */
    while (!(rd(EMB_REG_STATUS) & EMB_ST_DONE)) { }

    uint32_t status = rd(EMB_REG_STATUS);
    uint32_t irq = rd(EMB_REG_IRQ);

    if (st) {
        st->desc    = rd(EMB_REG_ST_DESC);
        st->idx     = rd(EMB_REG_ST_IDX);
        st->local   = rd(EMB_REG_ST_LOCAL);
        st->remote  = rd(EMB_REG_ST_REMOTE);
        st->invalid = rd(EMB_REG_ST_INVALID);
        st->rbeats  = rd(EMB_REG_ST_RBEATS);
        st->wbeats  = rd(EMB_REG_ST_WBEATS);
        st->err_baglen = (status & EMB_ST_ERR_BAGLEN) ? 1u : 0u;
    }

    /* acknowledge both flags write-1-to-clear */
    wr(EMB_REG_IRQ, irq & (EMB_IRQ_DONE | EMB_IRQ_ERROR));

    /* STAT_REMOTE is the number of rows this device did not own: the runtime
     * uses it to size the all-to-all that gathers the peer shards' partials. */
    if (status & (EMB_ST_ERR_BAGLEN | EMB_ST_ERR_INDEX | EMB_ST_ERR_BUS))
        return (int)(status & 0x1Cu);
    return 0;
}

/* ------------------------------------------------- host-side reference compute */
/* Recompute the pooled vectors on the CPU so the driver can self-check a batch
 * during bring-up; this is the same specification as sw/emb_model.c. */
void emb_check_batch(const uint32_t *mem, const uint32_t *dev_out,
                     uint32_t desc_base, uint32_t desc_count, uint32_t idx_base,
                     uint32_t tab_base, uint32_t out_base, uint32_t shard_lo,
                     uint32_t shard_hi, uint32_t table_rows,
                     uint32_t *mismatches, uint32_t *checks)
{
    static uint32_t ref[EMB_MEM_WORDS];
    emb_cfg_t cfg = { shard_lo, shard_hi, table_rows };
    emb_stats_t st;
    uint32_t bad = 0, n = 0;

    for (uint32_t i = 0; i < EMB_MEM_WORDS; i++) ref[i] = mem[i];
    for (uint32_t i = 0; i < sizeof st / 4; i++) ((uint32_t *)&st)[i] = 0;

    emb_model_run(mem, ref, &cfg, desc_base, desc_count, idx_base, tab_base,
                  out_base, &st);

    for (uint32_t w = 0; w < desc_count * EMB_DIM; w++, n++)
        if (ref[out_base + w] != dev_out[w]) bad++;

    if (mismatches) *mismatches = bad;
    if (checks) *checks = n;
}
