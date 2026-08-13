/* =============================================================================
 * lob.h - shared definitions for the CAM-based limit-order-book / BBO engine.
 *
 * One single source of truth for the message/BBO bit layouts, the op codes and
 * the book parameters. The RTL (via generated tb/vectors/lob_const.vh) and the
 * software (this header) both derive their field offsets from QW / PW so the
 * hardware and the golden model stay byte-for-byte in agreement.
 * ========================================================================== */
#ifndef LOB_H
#define LOB_H

#include <stdint.h>

/* ---- book / field parameters (override from the Makefile with -D) ---- */
#ifndef QW
#define QW 24            /* aggregated quantity width (bits)              */
#endif
#ifndef PW
#define PW 16            /* price-tick width (bits)                       */
#endif
#ifndef N_LEVELS
#define N_LEVELS 32      /* CAM depth: distinct (side,price) levels held  */
#endif

/* ---- message beat (AXI4-Stream TDATA) field offsets, derived ---- */
#define MSG_QTY_LSB   0
#define MSG_PRICE_LSB (MSG_QTY_LSB + QW)     /* QW                */
#define MSG_SIDE_LSB  (MSG_PRICE_LSB + PW)   /* QW+PW             */
#define MSG_OP_LSB    (MSG_SIDE_LSB + 1)     /* QW+PW+1           */
#define MSG_OP_W      2
#define MSGW          64                     /* TDATA width       */

/* ---- BBO record (128-bit) field offsets, derived ---- */
#define BBO_BID_QTY_LSB   0
#define BBO_BID_PRICE_LSB (BBO_BID_QTY_LSB + QW)      /* QW           */
#define BBO_BID_VLD_LSB   (BBO_BID_PRICE_LSB + PW)    /* QW+PW        */
#define BBO_ASK_QTY_LSB   64
#define BBO_ASK_PRICE_LSB (BBO_ASK_QTY_LSB + QW)      /* 64+QW        */
#define BBO_ASK_VLD_LSB   (BBO_ASK_PRICE_LSB + PW)    /* 64+QW+PW     */
#define BBOW              128

/* ---- op codes ---- */
#define OP_ADD 0u   /* level.qty += qty ; allocate on miss (qty>0)          */
#define OP_SUB 1u   /* level.qty  = max(level.qty - qty, 0); free at zero   */
#define OP_SET 2u   /* level.qty  = qty ; allocate on miss ; free at zero   */
#define OP_CLR 3u   /* remove level (qty -> 0, free); no-op on miss         */

/* ---- sides ---- */
#define SIDE_BID 0u
#define SIDE_ASK 1u

/* ---- register map (32-bit MMIO) ---- */
#define REG_CTRL     0x00u   /* [0] soft_reset(clear book) [1] irq_enable    */
#define REG_STATUS   0x04u   /* [0] busy [1] overflow_sticky [2] irq_pending
                                [15:8] active_levels                          */
#define REG_MSGCOUNT 0x08u   /* messages committed since reset                */
#define REG_IRQACK   0x0Cu   /* write 1 -> clear bbo irq / overflow sticky    */
#define REG_BID_PX   0x10u   /* [PW-1:0] price [16] valid                     */
#define REG_BID_QTY  0x14u   /* [QW-1:0] qty                                  */
#define REG_ASK_PX   0x18u   /* [PW-1:0] price [16] valid                     */
#define REG_ASK_QTY  0x1Cu   /* [QW-1:0] qty                                  */

#define CTRL_SOFTRESET (1u << 0)
#define CTRL_IRQEN     (1u << 1)
#define STAT_BUSY      (1u << 0)
#define STAT_OVERFLOW  (1u << 1)
#define STAT_IRQPEND   (1u << 2)

/* ---- masks (host-side) ---- */
static const uint32_t QTY_MASK   = (QW >= 32) ? 0xFFFFFFFFu : ((1u << QW) - 1u);
static const uint32_t PRICE_MASK = (PW >= 32) ? 0xFFFFFFFFu : ((1u << PW) - 1u);

/* ---- decoded message ---- */
typedef struct {
    uint32_t op;
    uint32_t side;
    uint32_t price;
    uint32_t qty;
} msg_t;

/* ---- best-bid / best-offer snapshot ---- */
typedef struct {
    uint32_t bid_valid, bid_price, bid_qty;
    uint32_t ask_valid, ask_price, ask_qty;
} bbo_t;

/* pack a decoded message into a 64-bit AXI-Stream beat */
static inline uint64_t msg_pack(const msg_t *m)
{
    return ((uint64_t)(m->qty   & QTY_MASK)              << MSG_QTY_LSB)   |
           ((uint64_t)(m->price & PRICE_MASK)            << MSG_PRICE_LSB) |
           ((uint64_t)(m->side  & 1u)                    << MSG_SIDE_LSB)  |
           ((uint64_t)(m->op    & 3u)                    << MSG_OP_LSB);
}

/* pack a BBO snapshot into a 128-bit record (returned as two 64-bit halves) */
static inline void bbo_pack(const bbo_t *b, uint64_t *hi, uint64_t *lo)
{
    *lo = ((uint64_t)(b->bid_qty   & QTY_MASK)   << BBO_BID_QTY_LSB)                 |
          ((uint64_t)(b->bid_price & PRICE_MASK) << BBO_BID_PRICE_LSB)               |
          ((uint64_t)(b->bid_valid & 1u)         << BBO_BID_VLD_LSB);
    *hi = ((uint64_t)(b->ask_qty   & QTY_MASK)   << (BBO_ASK_QTY_LSB   - 64))        |
          ((uint64_t)(b->ask_price & PRICE_MASK) << (BBO_ASK_PRICE_LSB - 64))        |
          ((uint64_t)(b->ask_valid & 1u)         << (BBO_ASK_VLD_LSB   - 64));
}

/* ---- golden reference book (matches the CAM hardware bit-for-bit) ---- */
void   lob_reset(void);
void   lob_apply(const msg_t *m);   /* apply one message to the book       */
void   lob_bbo(bbo_t *out);         /* read current best-bid/offer         */
int    lob_overflow(void);          /* sticky overflow flag                */
int    lob_active(void);            /* number of active price levels       */

/* ---- scalar CPU baseline cost model ---- */
uint64_t lob_baseline_cycles(const msg_t *msgs, int n);
/* total baseline cycles, and the worst single-message cost (peak) */
void     lob_baseline_stats(const msg_t *msgs, int n,
                            uint64_t *total, uint64_t *peak_permsg);

#endif /* LOB_H */
