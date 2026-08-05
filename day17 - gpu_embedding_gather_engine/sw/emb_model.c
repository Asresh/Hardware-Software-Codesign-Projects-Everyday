/* emb_model.c - bit-exact reference model for the embedding gather-reduce engine.
 *
 * This is the specification.  The RTL is checked word-for-word against the
 * memory image this function produces, and register-for-register against the
 * statistics it counts.  Everything is exact 32-bit integer arithmetic:
 *
 *   - SUM / MEAN accumulate with two's-complement wraparound (uint32 add),
 *   - MAX / MIN are signed comparisons,
 *   - MEAN divides the accumulated sum by the number of *locally* pooled rows,
 *     truncating toward zero (C99 `/` semantics on int32_t),
 *   - a bag whose indices all belong to peer shards pools nothing and emits a
 *     zero vector, which is what the all-to-all reduce downstream expects.
 */
#include "emb.h"

static inline int32_t wadd(int32_t a, int32_t b)
{
    return (int32_t)((uint32_t)a + (uint32_t)b);
}

void emb_model_run(const uint32_t *mem, uint32_t *out_mem, const emb_cfg_t *cfg,
                   uint32_t desc_base, uint32_t desc_count, uint32_t idx_base,
                   uint32_t tab_base, uint32_t out_base, emb_stats_t *st)
{
    int32_t acc[EMB_DIM];

    for (uint32_t d = 0; d < desc_count; d++) {
        const uint32_t *dw = &mem[desc_base + d * EMB_DESC_WORDS];
        uint32_t op = dw[0] & 3u;
        uint32_t num_idx = dw[1];
        uint32_t idx_off = dw[2];
        uint32_t dst_off = dw[3];

        st->desc++;
        /* the descriptor fetch itself is one burst of DESC_WORDS/LANES beats */
        st->rbeats += EMB_DESC_WORDS / EMB_LANES;

        if (num_idx > EMB_MAX_BAG) {
            /* the index buffer cannot hold the bag: reject, write nothing */
            st->err_baglen++;
            continue;
        }

        if (num_idx) {
            /* index list is fetched as ceil(num_idx / LANES) beats */
            st->rbeats += (num_idx + EMB_LANES - 1) / EMB_LANES;
        }

        uint32_t cnt = 0;
        for (uint32_t j = 0; j < num_idx; j++) {
            uint32_t ix = mem[idx_base + idx_off + j];
            st->idx++;

            if (ix >= cfg->table_rows) {
                st->invalid++;
                continue;
            }
            if (ix < cfg->shard_lo || ix >= cfg->shard_hi) {
                st->remote++;
                continue;
            }

            const uint32_t *row = &mem[tab_base + (ix - cfg->shard_lo) * EMB_DIM];
            st->local++;
            st->rbeats += EMB_CHUNKS;

            for (uint32_t e = 0; e < EMB_DIM; e++) {
                int32_t v = (int32_t)row[e];
                if (cnt == 0) {
                    acc[e] = v;
                } else {
                    switch (op) {
                    case EMB_OP_SUM:
                    case EMB_OP_MEAN: acc[e] = wadd(acc[e], v); break;
                    case EMB_OP_MAX:  if (v > acc[e]) acc[e] = v; break;
                    default:          if (v < acc[e]) acc[e] = v; break;
                    }
                }
            }
            cnt++;
        }

        uint32_t *dst = &out_mem[out_base + dst_off];
        if (cnt == 0) {
            for (uint32_t e = 0; e < EMB_DIM; e++) dst[e] = 0;
        } else if (op == EMB_OP_MEAN) {
            for (uint32_t e = 0; e < EMB_DIM; e++)
                dst[e] = (uint32_t)(acc[e] / (int32_t)cnt);
        } else {
            for (uint32_t e = 0; e < EMB_DIM; e++) dst[e] = (uint32_t)acc[e];
        }
        st->wbeats += EMB_CHUNKS;
    }
}
