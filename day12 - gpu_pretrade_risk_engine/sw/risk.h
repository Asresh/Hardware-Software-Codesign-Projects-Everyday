/* ===========================================================================
 * risk.h - shared contract for the pre-trade risk / market-access engine
 *
 * One header, three consumers: the golden reference (risk_ref.c), the scalar
 * baseline cost model (risk_baseline.c), and the bare-metal firmware driver
 * (risk_driver.c). The RTL mirrors every constant here bit-for-bit; the
 * differential testbench is the proof.
 * ===========================================================================
 */
#ifndef RISK_H
#define RISK_H

#include <stdint.h>

/* ---- design parameters (must match rtl defaults / -P overrides) ---- */
#ifndef SYM_N
#define SYM_N   32          /* number of configurable symbols            */
#endif
#ifndef ACCT_N
#define ACCT_N  8           /* number of configurable accounts           */
#endif
#define POS_N   (SYM_N*ACCT_N)   /* per (account,symbol) position slots  */

/* ---- rejection reason codes (also the priority-encoder order) ---- */
enum {
    REJ_NONE      = 0,   /* accepted                                     */
    REJ_KILL      = 1,   /* global kill switch engaged (highest prio)    */
    REJ_RANGE     = 2,   /* symbol/account id out of configured range    */
    REJ_HALT      = 3,   /* symbol or account disabled (trading halt)    */
    REJ_PRICEBAND = 4,   /* price outside fat-finger band [lo,hi]        */
    REJ_MAXQTY    = 5,   /* qty == 0 or qty > per-symbol max order size  */
    REJ_NOTIONAL  = 6,   /* price*qty > per-symbol max notional          */
    REJ_POSLIMIT  = 7,   /* |net position + signed qty| > pos limit      */
    REJ_MSGCOUNT  = 8,   /* per-account accepted-order count cap reached */
    REJ__COUNT    = 9
};

/* ---- side ---- */
#define SIDE_BUY   0
#define SIDE_SELL  1

/* ---- an inbound order (packs into a 128-bit AXI4-Stream ingress beat) ---- */
typedef struct {
    uint16_t symbol;     /* [15:0]    */
    uint16_t account;    /* [31:16]   */
    uint32_t price;      /* [63:32]   ticks */
    uint32_t qty;        /* [95:64]   */
    uint32_t order_id;   /* [119:96]  24-bit tag */
    uint8_t  side;       /* [120]     0=buy 1=sell */
} order_t;

/* ---- a risk decision (packs into a 128-bit AXI4-Stream egress beat) ---- */
typedef struct {
    uint32_t order_id;   /* [23:0]    */
    uint8_t  accept;     /* [24]      */
    uint8_t  reason;     /* [28:25]   */
    uint16_t symbol;     /* [47:32]   */
    uint8_t  account;    /* [55:48]   */
    int32_t  out_pos;    /* [95:64]   net position after (accept) / current */
} decision_t;

/* ---- per-symbol configuration (policy computed in software) ---- */
typedef struct {
    uint32_t price_lo;      /* fat-finger lower bound (inclusive) */
    uint32_t price_hi;      /* fat-finger upper bound (inclusive) */
    uint32_t max_qty;       /* max order size                     */
    uint64_t max_notional;  /* max price*qty per order            */
    uint8_t  enabled;       /* 1 = tradable, 0 = halted           */
} sym_cfg_t;

/* ---- per-account configuration ---- */
typedef struct {
    uint32_t pos_limit;     /* max |net position| per symbol      */
    uint32_t max_msgs;      /* max accepted orders (message cap)   */
    uint8_t  enabled;       /* 1 = active, 0 = disabled           */
} acct_cfg_t;

/* ---- full engine configuration ---- */
typedef struct {
    sym_cfg_t  sym[SYM_N];
    acct_cfg_t acct[ACCT_N];
    uint8_t    kill_switch;     /* global market-access kill        */
} risk_cfg_t;

/* ---- mutable engine state (position + accepted-order counters) ---- */
typedef struct {
    int32_t  pos[POS_N];        /* net position per (account,symbol) */
    uint32_t count[ACCT_N];     /* accepted-order count per account  */
    /* aggregate statistics */
    uint32_t total, accepted, rejected;
    uint32_t rej[REJ__COUNT];
} risk_state_t;

/* ---- APB register map (byte addresses) ---- */
#define REG_CTRL         0x000  /* [0]kill [1]enable [2]irq_en [3]soft_reset(W1) */
#define REG_STATUS       0x004  /* [0]irq [1]kill [2]clr_busy                    */
#define REG_IRQ_ACK      0x008  /* W1C clears irq_pending                        */
#define REG_TOTAL        0x00C
#define REG_ACCEPTED     0x010
#define REG_REJECTED     0x014
#define REG_LAST         0x018  /* [3:0]reason [31:8]last order_id               */
#define REG_REJ_BASE     0x01C  /* REG_REJ_BASE + reason*4 (reason 1..8)         */
#define REG_VERSION      0x0FC  /* magic                                         */
#define RISK_MAGIC       0x15C30512u

#define SYM_TBL_BASE     0x400  /* + sym*0x20 + word*4 (6 words used)            */
#define SYM_STRIDE       0x20
#define ACCT_TBL_BASE    0x800  /* + acct*0x10 + word*4 (4 words used)          */
#define ACCT_STRIDE      0x10

/* CTRL bit fields */
#define CTRL_KILL        (1u<<0)
#define CTRL_ENABLE      (1u<<1)
#define CTRL_IRQEN       (1u<<2)
#define CTRL_SOFTRST     (1u<<3)

/* ---- reference model / helpers (implemented in risk_ref.c) ---- */
const char *reason_name(int r);
void risk_reset_state(risk_state_t *st);
/* evaluate one order against cfg+state, mutate state on accept, fill decision */
void risk_eval(const risk_cfg_t *cfg, risk_state_t *st,
               const order_t *o, decision_t *d);

#endif /* RISK_H */
