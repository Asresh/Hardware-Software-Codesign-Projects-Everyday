/* =============================================================================
 * lob_driver.c - bare-metal firmware driver for the order-book engine.
 *
 * Illustrates the real control path a feed handler would run: soft-reset the
 * book, stream normalised market-data messages into the AXI4-Stream ingress
 * port, and read the best bid/offer either by polling or on the BBO-update
 * interrupt. This file is compiled (build-checked) but not linked into the
 * simulation host; the MMIO / stream accesses target the memory-mapped device.
 * ========================================================================== */
#include "lob.h"

#define LOB_MMIO_BASE  0x40040000u   /* control / snapshot register window   */
#define LOB_STREAM_FIFO 0x40041000u  /* AXI-Stream ingress push window (64b) */

#define REG(off)   (*(volatile uint32_t *)(uintptr_t)(LOB_MMIO_BASE + (off)))
#define STREAM_LO  (*(volatile uint32_t *)(uintptr_t)(LOB_STREAM_FIFO + 0))
#define STREAM_HI  (*(volatile uint32_t *)(uintptr_t)(LOB_STREAM_FIFO + 4))

/* clear the book and enable the BBO-update interrupt */
void lob_dev_init(void)
{
    REG(REG_CTRL) = CTRL_SOFTRESET;          /* pulse soft reset            */
    while (REG(REG_STATUS) & STAT_BUSY)      /* wait for the flush to drain */
        ;
    REG(REG_CTRL) = CTRL_IRQEN;              /* arm the interrupt           */
}

/* push one normalised message onto the streaming ingress port */
void lob_dev_push(const msg_t *m)
{
    uint64_t beat = msg_pack(m);
    STREAM_LO = (uint32_t)(beat & 0xFFFFFFFFu);
    STREAM_HI = (uint32_t)(beat >> 32);      /* HI write commits the beat   */
}

/* read the current top of book */
void lob_dev_bbo(bbo_t *b)
{
    uint32_t bpx = REG(REG_BID_PX), apx = REG(REG_ASK_PX);
    b->bid_valid = (bpx >> PW) & 1u;
    b->bid_price = bpx & PRICE_MASK;
    b->bid_qty   = REG(REG_BID_QTY) & QTY_MASK;
    b->ask_valid = (apx >> PW) & 1u;
    b->ask_price = apx & PRICE_MASK;
    b->ask_qty   = REG(REG_ASK_QTY) & QTY_MASK;
}

/* interrupt service routine: latch the new BBO, then acknowledge */
volatile int      g_bbo_ready;
volatile bbo_t    g_bbo;
volatile uint32_t g_overflow;

void lob_dev_isr(void)
{
    uint32_t st = REG(REG_STATUS);
    if (st & STAT_IRQPEND) {
        bbo_t b; lob_dev_bbo(&b);
        g_bbo = b;
        g_overflow = (st & STAT_OVERFLOW) ? 1u : 0u;
        g_bbo_ready = 1;
        REG(REG_IRQACK) = 1u;                /* clear the pending flag      */
    }
}

/* run a whole normalised feed and report the final top of book */
void lob_dev_run_feed(const msg_t *msgs, int n, bbo_t *final_bbo)
{
    lob_dev_init();
    for (int i = 0; i < n; i++)
        lob_dev_push(&msgs[i]);
    while (REG(REG_MSGCOUNT) < (uint32_t)n)  /* drain the pipeline          */
        ;
    lob_dev_bbo(final_bbo);
}
