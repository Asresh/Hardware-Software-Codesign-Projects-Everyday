/* emb_baseline.c - software-only scalar baseline for the same work.
 *
 * The accelerator is compared against a CPU doing sharded EmbeddingBag pooling
 * the ordinary way.  Rather than time a host machine (which would make the
 * "speedup" a property of whatever laptop ran the build), the baseline is an
 * explicit cost model: one cycle per modelled scalar operation, listed below,
 * evaluated over exactly the same descriptor ring the hardware executes.
 *
 *   descriptor decode        6   load 4 fields, bounds-check the bag length
 *   per index, classify      6   load index, compare against table_rows,
 *                                compare against shard_lo and shard_hi
 *   per index, address       4   subtract shard_lo, multiply by EMB_DIM,
 *                                add table base, form the loop bound
 *   per element, first row   3   load, store into the accumulator, bump pointers
 *   per element, fold        4   load, add or compare-select, store, bump
 *   per element, mean        22  32-bit integer divide (20) + store + bump
 *   per element, copy out    2   load accumulator, store to the output vector
 *   empty bag                2   per element, store zero
 *
 * These are deliberately generous towards the CPU: the fold is counted as a
 * single fused load/op/store pair per element with no loop overhead, no cache
 * misses on the 4 KB-per-row table walk, and no branch mispredicts on the
 * shard classification, all of which a real core pays for on this access
 * pattern.  `ops_out` returns the modelled operation count so the README can
 * state the cost model and the work it was evaluated over.
 */
#include "emb.h"

#define C_DESC 6
#define C_CLASSIFY 6
#define C_ADDR 4
#define C_FIRST 3
#define C_FOLD 4
#define C_MEAN 22
#define C_COPY 2
#define C_ZERO 2

uint64_t emb_baseline_cycles(const uint32_t *mem, const emb_cfg_t *cfg,
                             uint32_t desc_base, uint32_t desc_count,
                             uint32_t idx_base, uint64_t *ops_out)
{
    uint64_t cyc = 0, ops = 0;

    for (uint32_t d = 0; d < desc_count; d++) {
        const uint32_t *dw = &mem[desc_base + d * EMB_DESC_WORDS];
        uint32_t op = dw[0] & 3u;
        uint32_t num_idx = dw[1];
        uint32_t idx_off = dw[2];

        cyc += C_DESC;
        ops++;
        if (num_idx > EMB_MAX_BAG) continue;

        uint32_t cnt = 0;
        for (uint32_t j = 0; j < num_idx; j++) {
            uint32_t ix = mem[idx_base + idx_off + j];
            cyc += C_CLASSIFY;
            ops++;
            if (ix >= cfg->table_rows) continue;
            if (ix < cfg->shard_lo || ix >= cfg->shard_hi) continue;

            cyc += C_ADDR;
            ops++;
            cyc += (uint64_t)EMB_DIM * (cnt == 0 ? C_FIRST : C_FOLD);
            ops += EMB_DIM;
            cnt++;
        }

        if (cnt == 0) {
            cyc += (uint64_t)EMB_DIM * C_ZERO;
            ops += EMB_DIM;
        } else if (op == EMB_OP_MEAN) {
            cyc += (uint64_t)EMB_DIM * C_MEAN;
            ops += EMB_DIM;
        } else {
            cyc += (uint64_t)EMB_DIM * C_COPY;
            ops += EMB_DIM;
        }
    }

    if (ops_out) *ops_out = ops;
    return cyc;
}
