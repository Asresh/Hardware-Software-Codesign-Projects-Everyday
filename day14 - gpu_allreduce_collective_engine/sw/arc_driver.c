/* ============================================================================
 * arc_driver.c - bare-metal firmware driver for the all-reduce collective
 *                engine.
 *
 * This is the software half of the co-design: it builds a descriptor ring in
 * shared memory, programs the ring base/count over MMIO, kicks the engine,
 * and services the completion / error interrupt.  Compiled as a build/interface
 * check (the simulation drives the RTL from the testbench); it is written the
 * way it would run on the host core next to the accelerator.
 * ==========================================================================*/
#include "arc.h"
#include <stddef.h>

#define ARC_CSR_BASE 0x40000000u
#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define CSR(off) REG32(ARC_CSR_BASE + (off))

/* Fill one collective descriptor in shared memory (word addresses). */
void arc_build_desc(uint32_t *mem, uint32_t desc_base, int op, uint32_t n,
                    uint32_t dst_base, const uint32_t *src_base, int r)
{
    int i;
    mem[desc_base + ARC_D_CTRL] = (uint32_t)(op & ARC_CTRL_OP_MASK) | ARC_CTRL_VALID;
    mem[desc_base + ARC_D_N]    = n;
    mem[desc_base + ARC_D_DST]  = dst_base;
    for (i = 0; i < r; i++) mem[desc_base + ARC_D_SRC0 + i] = src_base[i];
}

/* Program the ring and start the engine. */
void arc_launch(uint32_t desc_base_words, uint32_t desc_count, int irq_enable)
{
    CSR(REG_CTRL)      = CTRL_SRESET;                 /* clear counters/state   */
    CSR(REG_DESC_BASE) = desc_base_words;
    CSR(REG_DESC_COUNT)= desc_count;
    CSR(REG_SCRATCH)   = 0xC0DE5EEDu;                 /* bus sanity             */
    CSR(REG_CTRL)      = CTRL_START | (irq_enable ? CTRL_IRQEN : 0);
}

/* Poll for completion; returns 0 done, <0 on engine error. */
int arc_wait(void)
{
    uint32_t st;
    do { st = CSR(REG_STATUS); } while (st & STATUS_BUSY);
    if (st & STATUS_ERR) return -(int)CSR(REG_ERRCODE);
    return 0;
}

/* completion / error ISR: read stats, clear the sticky bits (W1C). */
void arc_isr(uint32_t *completed_out)
{
    uint32_t st = CSR(REG_STATUS);
    if (st & (STATUS_DONE | STATUS_ERR)) {
        if (completed_out) *completed_out = CSR(REG_COMPLETED);
        CSR(REG_STATUS) = (st & (STATUS_DONE | STATUS_ERR)); /* write-1-to-clear */
    }
}

uint32_t arc_words_reduced(void) { return CSR(REG_WORDS); }
