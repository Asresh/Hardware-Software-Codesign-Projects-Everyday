/* ==========================================================================
 * asig_driver.c - bare-metal driver for the alpha-signal engine.
 *
 * Programs the AXI4-Lite control plane, streams ticks into the ingress, drains
 * signal records from the egress, and services the alert interrupt.  This is
 * the firmware that would run on the host/soft-core beside the accelerator; it
 * is build-checked in CI (compiled but not linked against real MMIO).
 * ========================================================================== */
#include <stdint.h>
#include "asig.h"

/* ---- AXI4-Lite register block (byte offsets) ---- */
#define ASIG_CTRL      0x00u   /* [0] enable [1] soft_reset [2] irq_enable */
#define ASIG_ALPHA     0x04u
#define ASIG_BETA      0x08u
#define ASIG_GAMMA     0x0Cu
#define ASIG_ZTHRESH   0x10u
#define ASIG_WARMUP    0x14u
#define ASIG_STATUS    0x18u   /* [0] busy [1] irq */
#define ASIG_TICKCNT   0x1Cu
#define ASIG_RECCNT    0x20u
#define ASIG_ALERTCNT  0x24u
#define ASIG_IRQACK    0x28u

#define CTRL_ENABLE    (1u << 0)
#define CTRL_SOFTRST   (1u << 1)
#define CTRL_IRQEN     (1u << 2)
#define STATUS_BUSY    (1u << 0)
#define STATUS_IRQ     (1u << 1)

/* AXI4-Stream data-mover windows (platform-mapped) */
typedef struct { volatile uint64_t tick; } asig_ingress_t;   /* {sym,price} */
typedef struct { volatile uint32_t word[REC_WORDS]; } asig_egress_t;

static inline void  reg_wr(volatile uint8_t *b, uint32_t o, uint32_t v){ *(volatile uint32_t*)(b+o)=v; }
static inline uint32_t reg_rd(volatile uint8_t *b, uint32_t o){ return *(volatile uint32_t*)(b+o); }

/* one-time configuration + soft reset */
void asig_configure(volatile uint8_t *regs, const asig_cfg_t *cfg)
{
    reg_wr(regs, ASIG_ALPHA,   (uint32_t)cfg->alpha);
    reg_wr(regs, ASIG_BETA,    (uint32_t)cfg->beta);
    reg_wr(regs, ASIG_GAMMA,   (uint32_t)cfg->gamma);
    reg_wr(regs, ASIG_ZTHRESH, (uint32_t)cfg->zthresh);
    reg_wr(regs, ASIG_WARMUP,  cfg->warmup);
    reg_wr(regs, ASIG_CTRL,    CTRL_ENABLE | CTRL_SOFTRST | CTRL_IRQEN);
    while (reg_rd(regs, ASIG_STATUS) & STATUS_BUSY) { /* wait clear */ }
}

/* push one tick (blocks until the stream engine accepts it) */
static inline void asig_push(asig_ingress_t *in, uint32_t sym, int32_t price)
{
    in->tick = ((uint64_t)sym << 32) | (uint32_t)price;
}

/* pull one signal record into out[] */
static inline void asig_pull(const asig_egress_t *eg, uint32_t out[REC_WORDS])
{
    for (int i = 0; i < REC_WORDS; i++) out[i] = eg->word[i];
}

/* stream a batch of ticks and collect one record each */
uint32_t asig_run_batch(volatile uint8_t *regs, asig_ingress_t *in,
                        asig_egress_t *eg, const asig_tick_t *ticks, uint32_t n,
                        uint32_t records[][REC_WORDS])
{
    uint32_t got = 0;
    for (uint32_t i = 0; i < n; i++) {
        asig_push(in, ticks[i].sym, ticks[i].price);
        asig_pull(eg, records[got++]);        /* 1 record per tick */
    }
    (void)reg_rd(regs, ASIG_RECCNT);
    return got;
}

/* interrupt handler: latch alerts and acknowledge */
volatile uint32_t asig_alert_events;
void asig_isr(volatile uint8_t *regs)
{
    if (reg_rd(regs, ASIG_STATUS) & STATUS_IRQ) {
        asig_alert_events = reg_rd(regs, ASIG_ALERTCNT);
        reg_wr(regs, ASIG_IRQACK, 1u);        /* W1C */
    }
}
