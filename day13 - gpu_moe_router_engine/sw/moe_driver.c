/* ============================================================================
 * moe_driver.c - bare-metal firmware driver for the MoE router engine.
 *
 * This is the software half of the co-design: it programs the capacity and
 * interrupt controls over AXI4-Lite, streams token logit-vectors into the
 * ingress AXI4-Stream port, drains dispatch records from the egress port, and
 * services the over-capacity interrupt.  Compiled as a build/interface check
 * (the simulation drives the RTL directly from the testbench); it is written
 * the way it would run on the host core beside the accelerator.
 * ==========================================================================*/
#include "moe.h"
#include <stddef.h>

/* memory-mapped bases (placeholders for a real SoC address map) */
#define MOE_CSR_BASE    0x40000000u
#define MOE_TX_FIFO     0x40010000u   /* ingress logit-beat data port         */
#define MOE_TX_PUSH     0x40010004u   /* write 1 to commit a beat             */
#define MOE_RX_FIFO     0x40010008u   /* egress record data port              */
#define MOE_RX_VALID    0x4001000Cu   /* [0]=record available                 */

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define CSR(off) REG32(MOE_CSR_BASE + (off))

void moe_configure(uint32_t cap, int irq_enable)
{
    CSR(REG_CTRL)   = CTRL_SRESET;                 /* clear load counters      */
    CSR(REG_CAP)    = cap;
    CSR(REG_SCRATCH) = 0xC0DE5EEDu;                /* bus sanity               */
    CSR(REG_CTRL)   = CTRL_ENABLE | (irq_enable ? CTRL_IRQEN : 0);
}

/* push one token's E logits into the ingress stream */
void moe_submit(const int16_t logit[MOE_E])
{
    int i;
    for (i = 0; i < MOE_E; i += 2) {
        uint32_t lane = (uint16_t)logit[i] | ((uint32_t)(uint16_t)logit[i + 1] << 16);
        REG32(MOE_TX_FIFO + (i / 2) * 4) = lane;
    }
    REG32(MOE_TX_PUSH) = 1;                         /* commit the beat          */
}

/* blocking drain of one dispatch record */
int moe_collect(moe_record_t *rec)
{
    if (!(REG32(MOE_RX_VALID) & 1)) return 0;
    uint32_t l0 = REG32(MOE_RX_FIFO + 0);
    uint32_t l1 = REG32(MOE_RX_FIFO + 4);
    uint32_t l2 = REG32(MOE_RX_FIFO + 8);
    uint32_t l3 = REG32(MOE_RX_FIFO + 12);

    rec->token_id    = (uint16_t)(l0 & 0xFFFF);
    rec->weight[0]   = l1 & ((1u << MOE_WEIGHT_W) - 1);
    rec->expert[0]   = (uint8_t)((l1 >> MOE_WEIGHT_W) & 0xFF);
    rec->overflow[0] = (uint8_t)((l1 >> 31) & 1);
    rec->weight[1]   = l2 & ((1u << MOE_WEIGHT_W) - 1);
    rec->expert[1]   = (uint8_t)((l2 >> MOE_WEIGHT_W) & 0xFF);
    rec->overflow[1] = (uint8_t)((l2 >> 31) & 1);
    rec->routed      = (uint8_t)(l3 & 0xFF);
    return 1;
}

/* over-capacity interrupt handler: read stats, clear the sticky bit (W1C) */
void moe_isr(uint32_t *dropped_out)
{
    if (CSR(REG_STATUS) & STATUS_OVF_IRQ) {
        if (dropped_out) *dropped_out = CSR(REG_OVERFLOWS);
        CSR(REG_STATUS) = STATUS_OVF_IRQ;          /* write-1-to-clear         */
    }
}

/* read a per-expert accepted-token load counter */
uint32_t moe_expert_load(int e)
{
    return CSR(REG_EXPLOAD0 + (uint32_t)e * 4);
}
