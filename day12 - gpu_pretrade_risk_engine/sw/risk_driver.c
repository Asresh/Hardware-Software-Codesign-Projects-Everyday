/* ===========================================================================
 * risk_driver.c - bare-metal firmware driver for the pre-trade risk engine.
 *
 * This is the production control path: how host firmware programs the limits
 * over APB, streams orders in, drains decisions, and services the violation
 * interrupt. It is compile-checked in CI (built to /dev/null) but written as
 * real MMIO firmware - it is what would run on the embedded core beside the
 * FPGA. No simulator hooks, no printf in the hot path.
 * ===========================================================================
 */
#include "risk.h"
#include <stdint.h>

/* ---- platform MMIO base addresses (board-specific) ---- */
#define APB_BASE   0x40000000u        /* APB control/status window          */
#define TX_FIFO    0x40100000u        /* AXI4-Stream order ingress (128b)   */
#define RX_FIFO    0x40200000u        /* AXI4-Stream decision egress (128b) */

#define APB_REG(o) (*(volatile uint32_t *)(APB_BASE + (o)))
#define STREAM(a)  (*(volatile uint32_t *)(a))

/* ---- APB register access ---- */
static inline void apb_wr(uint32_t off, uint32_t val) { APB_REG(off) = val; }
static inline uint32_t apb_rd(uint32_t off) { return APB_REG(off); }

/* ---- program one symbol's limits ---- */
void risk_program_symbol(unsigned s, const sym_cfg_t *c) {
    uint32_t b = SYM_TBL_BASE + s * SYM_STRIDE;
    apb_wr(b + 0x00, c->price_lo);
    apb_wr(b + 0x04, c->price_hi);
    apb_wr(b + 0x08, c->max_qty);
    apb_wr(b + 0x0C, (uint32_t)(c->max_notional & 0xFFFFFFFFu));
    apb_wr(b + 0x10, (uint32_t)(c->max_notional >> 32));
    apb_wr(b + 0x14, c->enabled ? 1u : 0u);
}

/* ---- program one account's limits ---- */
void risk_program_account(unsigned a, const acct_cfg_t *c) {
    uint32_t b = ACCT_TBL_BASE + a * ACCT_STRIDE;
    apb_wr(b + 0x00, c->pos_limit);
    apb_wr(b + 0x04, c->max_msgs);
    apb_wr(b + 0x08, c->enabled ? 1u : 0u);
}

/* ---- program the whole configuration ---- */
void risk_configure(const risk_cfg_t *cfg) {
    for (unsigned s = 0; s < SYM_N; s++)  risk_program_symbol(s, &cfg->sym[s]);
    for (unsigned a = 0; a < ACCT_N; a++) risk_program_account(a, &cfg->acct[a]);
    uint32_t ctrl = CTRL_ENABLE | CTRL_IRQEN | (cfg->kill_switch ? CTRL_KILL : 0);
    apb_wr(REG_CTRL, ctrl);
}

/* ---- clear the mutable state (position + counts + stats) ---- */
void risk_soft_reset(void) {
    apb_wr(REG_CTRL, apb_rd(REG_CTRL) | CTRL_SOFTRST);
    while (apb_rd(REG_STATUS) & (1u << 2)) { /* wait for clr_busy */ }
}

/* ---- submit one order (blocks until ingress FIFO accepts) ---- */
void risk_submit(const order_t *o) {
    uint32_t w0 = ((uint32_t)o->symbol) | ((uint32_t)o->account << 16);
    uint32_t w1 = o->price;
    uint32_t w2 = o->qty;
    uint32_t w3 = (o->order_id & 0x00FFFFFFu) | ((uint32_t)(o->side & 1) << 24);
    STREAM(TX_FIFO + 0x0) = w0;
    STREAM(TX_FIFO + 0x4) = w1;
    STREAM(TX_FIFO + 0x8) = w2;
    STREAM(TX_FIFO + 0xC) = w3;   /* last write pushes the beat */
}

/* ---- pop one decision ---- */
void risk_collect(decision_t *d) {
    uint32_t w0 = STREAM(RX_FIFO + 0x0);
    uint32_t w2 = STREAM(RX_FIFO + 0x8);
    d->order_id = w0 & 0x00FFFFFFu;
    d->accept   = (w0 >> 24) & 1u;
    d->reason   = (w0 >> 25) & 0xFu;
    d->symbol   = (uint16_t)(STREAM(RX_FIFO + 0x4) & 0xFFFFu);
    d->account  = (uint8_t)((STREAM(RX_FIFO + 0x4) >> 16) & 0xFFu);
    d->out_pos  = (int32_t)w2;
}

/* ---- interrupt service routine: a limit was breached ---- */
volatile uint32_t g_violations, g_last_reason;
void risk_isr(void) {
    uint32_t st = apb_rd(REG_STATUS);
    if (st & 1u) {                              /* irq pending */
        g_last_reason = apb_rd(REG_LAST) & 0xFu;
        g_violations  = apb_rd(REG_REJECTED);
        apb_wr(REG_IRQ_ACK, 1u);                /* W1C */
    }
}

/* ---- run a batch: configure, stream, drain ---- */
void risk_run_batch(const risk_cfg_t *cfg, const order_t *o,
                    decision_t *d, int n) {
    risk_configure(cfg);
    for (int i = 0; i < n; i++) {
        risk_submit(&o[i]);
        risk_collect(&d[i]);
    }
}
