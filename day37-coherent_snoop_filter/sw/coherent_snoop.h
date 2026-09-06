/* Author: Asresh */
#ifndef COHERENT_SNOOP_H
#define COHERENT_SNOOP_H

#include <stdint.h>

#define COH_SETS 8u
#define COH_SET_BITS 3u
#define COH_NODES 4u
#define COH_WAYS 2u

enum coh_opcode {
    COH_READ_SHARED = 0,
    COH_READ_UNIQUE = 1,
    COH_WRITEBACK = 2,
    COH_EVICT = 3,
    COH_FLUSH_LINE = 4
};

struct coh_result {
    uint8_t hit;
    uint8_t error;
    uint8_t evicted;
    uint8_t probe_mask;
    uint8_t new_sharers;
};

struct coh_model {
    uint8_t valid[COH_SETS * COH_WAYS];
    uint16_t tag[COH_SETS * COH_WAYS];
    uint8_t sharers[COH_SETS * COH_WAYS];
    uint8_t dirty[COH_SETS * COH_WAYS];
    uint8_t replace_way[COH_SETS];
};

void coh_configure(volatile uint32_t *regs, int irq_enable);
void coh_ack_irq(volatile uint32_t *regs);
void coh_model_reset(struct coh_model *model);
struct coh_result coh_model_apply(struct coh_model *model, unsigned opcode,
                                  unsigned source, uint16_t address);

#endif
