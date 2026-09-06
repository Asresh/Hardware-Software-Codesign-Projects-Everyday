/* Author: Asresh */
#include "coherent_snoop.h"
#include <string.h>

void coh_model_reset(struct coh_model *model)
{
    if (model != 0)
        memset(model, 0, sizeof(*model));
}

struct coh_result coh_model_apply(struct coh_model *model, unsigned opcode,
                                  unsigned source, uint16_t address)
{
    struct coh_result result = {0, 0, 0, 0, 0};
    const unsigned set = (address >> 6) & (COH_SETS - 1u);
    const uint16_t tag = (uint16_t)(address >> (6u + COH_SET_BITS));
    const unsigned base = set * COH_WAYS;
    const uint8_t source_mask = (uint8_t)(1u << source);
    unsigned index;
    unsigned hit = 0;

    if (model == 0 || source >= COH_NODES || opcode > COH_FLUSH_LINE) {
        result.error = 1;
        return result;
    }
    if (model->valid[base] && model->tag[base] == tag) {
        index = base;
        hit = 1;
    } else if (model->valid[base + 1u] && model->tag[base + 1u] == tag) {
        index = base + 1u;
        hit = 1;
    } else if (!model->valid[base]) {
        index = base;
    } else if (!model->valid[base + 1u]) {
        index = base + 1u;
    } else {
        index = base + model->replace_way[set];
    }

    result.hit = (uint8_t)hit;
    result.new_sharers = hit ? model->sharers[index] : source_mask;
    if (opcode == COH_READ_SHARED) {
        if (hit) {
            result.probe_mask = model->dirty[index]
                ? (uint8_t)(model->sharers[index] & (uint8_t)~source_mask) : 0u;
            model->sharers[index] |= source_mask;
            model->dirty[index] = 0;
            result.new_sharers = model->sharers[index];
        } else {
            result.evicted = model->valid[index];
            result.probe_mask = model->valid[index] ? model->sharers[index] : 0u;
            model->valid[index] = 1;
            model->tag[index] = tag;
            model->sharers[index] = source_mask;
            model->dirty[index] = 0;
            model->replace_way[set] = (uint8_t)(!(index & 1u));
        }
    } else if (opcode == COH_READ_UNIQUE) {
        if (hit) {
            result.probe_mask = (uint8_t)(model->sharers[index] & (uint8_t)~source_mask);
        } else {
            result.evicted = model->valid[index];
            result.probe_mask = model->valid[index] ? model->sharers[index] : 0u;
            model->replace_way[set] = (uint8_t)(!(index & 1u));
        }
        model->valid[index] = 1;
        model->tag[index] = tag;
        model->sharers[index] = source_mask;
        model->dirty[index] = 1;
        result.new_sharers = source_mask;
    } else if (opcode == COH_WRITEBACK) {
        if (hit && (model->sharers[index] & source_mask))
            model->dirty[index] = 0;
        else
            result.error = 1;
    } else if (opcode == COH_EVICT) {
        if (hit && (model->sharers[index] & source_mask)) {
            model->sharers[index] &= (uint8_t)~source_mask;
            result.new_sharers = model->sharers[index];
            if (model->sharers[index] == 0u) {
                model->valid[index] = 0;
                model->dirty[index] = 0;
            }
        } else {
            result.error = 1;
        }
    } else if (opcode == COH_FLUSH_LINE) {
        if (hit) {
            result.probe_mask = model->sharers[index];
            result.new_sharers = 0;
            model->valid[index] = 0;
            model->sharers[index] = 0;
            model->dirty[index] = 0;
        }
    }
    return result;
}
