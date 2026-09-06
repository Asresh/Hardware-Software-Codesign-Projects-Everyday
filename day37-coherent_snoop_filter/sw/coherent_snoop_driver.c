/* Author: Asresh */
#include "coherent_snoop.h"

enum { REG_CTRL = 0, REG_IRQ_STATUS = 2 };

void coh_configure(volatile uint32_t *regs, int irq_enable)
{
    if (regs != 0)
        regs[REG_CTRL] = 1u | (irq_enable ? 2u : 0u) | 4u;
}

void coh_ack_irq(volatile uint32_t *regs)
{
    if (regs != 0)
        regs[REG_IRQ_STATUS] = 1u;
}
