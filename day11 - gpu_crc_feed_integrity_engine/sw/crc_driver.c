// ============================================================================
// crc_driver.c - bare-metal firmware driver for the feed-integrity engine
//
//   Control-plane orchestration lives in software because it changes rarely and
//   is not on the per-packet critical path: bring the engine up, arm the
//   interrupt, and - when a packet fails integrity - drain the snapshot
//   registers to log which channel dropped or corrupted a message. The packet
//   stream itself flows in over AXI4-Stream and never touches the CPU.
//
//   Built for the target (compile-checked in CI); the host test uses the same
//   register map through a simulated MMIO space.
// ============================================================================
#include <stdint.h>
#include "crc.h"

#ifndef CRC_BASE
#define CRC_BASE 0x44A00000u
#endif

static volatile uint32_t *const REG = (volatile uint32_t *)(uintptr_t)CRC_BASE;

static inline void     wr(uint32_t off, uint32_t v) { REG[off >> 2] = v; }
static inline uint32_t rd(uint32_t off)             { return REG[off >> 2]; }

// Bring the engine up: enable, arm IRQ, turn on sequence checking.
void crc_engine_start(void) {
    wr(REG_CTRL, CTRL_SOFT_RST);                        // clear counters + seq RAM
    wr(REG_CTRL, CTRL_EN | CTRL_IRQ_EN | CTRL_SEQ_CHK);
}

void crc_engine_stop(void) { wr(REG_CTRL, 0); }

int crc_engine_healthy(void) {
    return rd(REG_VERSION) == ((0xFEu << 24) | (0xEDu << 16) | 11u);
}

// One integrity record drained from the CSR snapshot on an interrupt.
typedef struct {
    uint16_t channel;
    uint32_t seq, exp_seq, crc, exp_crc;
    int crc_ok, seq_ok, frame_err;
} crc_report_t;

// ISR: read why the last packet failed, then clear the interrupt.
void crc_engine_isr(crc_report_t *r) {
    uint32_t st  = rd(REG_STATUS);
    r->channel   = (uint16_t)rd(REG_LAST_CHANNEL);
    r->seq       = rd(REG_LAST_SEQ);
    r->exp_seq   = rd(REG_LAST_EXP_SEQ);
    r->crc       = rd(REG_LAST_CRC);
    r->exp_crc   = rd(REG_LAST_EXP_CRC);
    r->crc_ok    = (st & STATUS_CRC_OK)    ? 1 : 0;
    r->seq_ok    = (st & STATUS_SEQ_OK)    ? 1 : 0;
    r->frame_err = (st & STATUS_FRAME_ERR) ? 1 : 0;
    wr(REG_IRQ_ACK, 1);                                 // W1C
}

uint32_t crc_engine_pkt_count(void)   { return rd(REG_PKT_COUNT); }
uint32_t crc_engine_err_count(void)   { return rd(REG_ERR_COUNT); }
uint32_t crc_engine_crc_errs(void)    { return rd(REG_CRC_ERR_COUNT); }
uint32_t crc_engine_gap_count(void)   { return rd(REG_GAP_COUNT); }
uint32_t crc_engine_frame_errs(void)  { return rd(REG_FRAME_ERR_COUNT); }
