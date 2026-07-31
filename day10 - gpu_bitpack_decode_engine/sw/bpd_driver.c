// ============================================================================
// bpd_driver.c  -  bare-metal firmware driver (compile-checked)
//
// Configures the engine over AXI4-Lite, streams a compressed block in through
// the ingress DMA, drains the decoded values from the egress DMA, and services
// the completion interrupt. Written against volatile MMIO; not run in the sim
// (the SystemVerilog testbench drives the same registers), but kept building so
// the register contract stays honest.
// ============================================================================
#include "bpd.h"

#define BPD_BASE   0x44A00000u   // AXI4-Lite CSR base (example platform)
#define BPD_S2MM   0x44A10000u   // egress stream DMA (values out)
#define BPD_MM2S   0x44A20000u   // ingress stream DMA (compressed in)

static inline void     reg_wr(uint32_t base, uint32_t off, uint32_t v) {
    *(volatile uint32_t *)(uintptr_t)(base + off) = v;
}
static inline uint32_t reg_rd(uint32_t base, uint32_t off) {
    return *(volatile uint32_t *)(uintptr_t)(base + off);
}

// kick a simple stream DMA (platform-specific; provided by the BSP)
extern void dma_start(uint32_t dma_base, uintptr_t buf, uint32_t bytes);
extern int  dma_done (uint32_t dma_base);

// Decode one compressed block of `in_words` 32-bit words into `out` (32-bit
// values, up to `out_cap`). Returns the number of decoded values, or -1 on err.
int bpd_decode_block(const uint32_t *in_words, uint32_t in_words_n,
                     int32_t *out, uint32_t out_cap) {
    // enable engine + interrupt, clear any prior status
    reg_wr(BPD_BASE, BPD_CTRL, CTRL_SOFT_RST);
    reg_wr(BPD_BASE, BPD_CTRL, CTRL_EN | CTRL_IRQ_EN);

    // arm egress capture, then push the compressed words in
    dma_start(BPD_S2MM, (uintptr_t)out, out_cap * 4u);
    dma_start(BPD_MM2S, (uintptr_t)in_words, in_words_n * 4u);

    // wait for the block-done interrupt (status.DONE / .ERR)
    uint32_t st;
    do { st = reg_rd(BPD_BASE, BPD_STATUS); } while (!(st & (ST_DONE | ST_ERR)));

    int rc;
    if (st & ST_ERR) {
        rc = -1;
    } else {
        while (!dma_done(BPD_S2MM)) { /* spin */ }
        rc = (int)reg_rd(BPD_BASE, BPD_VALUES);
    }
    reg_wr(BPD_BASE, BPD_IRQ_ACK, 1u);   // W1C: clear DONE/ERR/IRQ
    return rc;
}

// throughput / health counters for host-side logging
uint32_t bpd_blocks(void)  { return reg_rd(BPD_BASE, BPD_BLOCKS); }
uint32_t bpd_values(void)  { return reg_rd(BPD_BASE, BPD_VALUES); }
uint32_t bpd_cycles(void)  { return reg_rd(BPD_BASE, BPD_CYCLES); }
uint32_t bpd_id(void)      { return reg_rd(BPD_BASE, BPD_ID);     }
