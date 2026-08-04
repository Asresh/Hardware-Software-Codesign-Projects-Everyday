/* ============================================================================
 * ann_driver.c - bare-metal firmware that drives one ANN search on the engine.
 *
 * This is the software half of the co-design: it programs the query, kicks the
 * search, and (in a real system) an AXI4-Stream DMA feeds the database shard.
 * Compiled as a standalone build-check by the Makefile; the register sequence
 * mirrors exactly what the testbench performs on the DUT.
 * ==========================================================================*/
#include "ann.h"

/* memory-mapped register file base (placeholder for the build check) */
#ifndef ANN_MMIO_BASE
#define ANN_MMIO_BASE 0xA0010000u
#endif

static volatile uint32_t *const REG = (volatile uint32_t *)(uintptr_t)ANN_MMIO_BASE;

static inline void  reg_wr(int i, uint32_t v) { REG[i] = v; }
static inline uint32_t reg_rd(int i)          { return REG[i]; }

/* load the ANN_D int8 query into the query window (4 elements per word) */
void ann_load_query(const int8_t *q)
{
    int w;
    for (w = 0; w < REG_QUERY_WORDS; w++) {
        uint32_t word =  (uint32_t)(uint8_t)q[w * 4 + 0]
                      | ((uint32_t)(uint8_t)q[w * 4 + 1] << 8)
                      | ((uint32_t)(uint8_t)q[w * 4 + 2] << 16)
                      | ((uint32_t)(uint8_t)q[w * 4 + 3] << 24);
        reg_wr(REG_QUERY_BASE + w, word);
    }
}

/* start a search over a shard of n database vectors using the given metric */
void ann_start(int metric, uint32_t n)
{
    reg_wr(REG_NDB, n);
    reg_wr(REG_CTRL, CTRL_START | CTRL_IRQEN | (metric ? CTRL_METRIC : 0u));
}

/* block until the engine raises DONE, then read the top-K back out */
int ann_wait_results(ann_entry_t *out)
{
    int k;
    while ((reg_rd(REG_STATUS) & ST_DONE) == 0u) { /* spin or WFI */ }
    for (k = 0; k < ANN_K; k++) {
        out[k].score = (int32_t)reg_rd(REG_SCORE_BASE + k);
        out[k].id    = (int32_t)reg_rd(REG_ID_BASE + k);
    }
    reg_wr(REG_IRQ_ACK, 1u);                 /* W1C: clear DONE/IRQ */
    return ANN_K;
}
