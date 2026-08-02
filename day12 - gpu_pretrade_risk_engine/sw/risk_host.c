/* ===========================================================================
 * risk_host.c - vector generator + golden reference harness.
 *
 * Builds a randomized-but-reproducible engine configuration and a stream of
 * orders (a directed prefix that exercises every rejection reason, followed by
 * randomized traffic), runs the bit-exact golden model over it, and emits:
 *
 *   vectors/config.hex     APB (addr,data) writes that program the tables
 *   vectors/orders.hex     one 128-bit ingress beat per order
 *   vectors/golden.txt     expected decision per order
 *   vectors/risk_const.vh  sizes + aggregate expectations for the testbench
 *   vectors/sw_metrics.txt scalar-baseline cycle numbers
 * ===========================================================================
 */
#include "risk.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

long risk_baseline_cycles(const risk_cfg_t *cfg, const order_t *orders, int n);

/* ---- reproducible xorshift64* PRNG (independent of the DUT) ---- */
static uint64_t rng_s = 0x0BADC0DE12345678ull;
static uint64_t rng_next(void) {
    uint64_t x = rng_s;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    rng_s = x;
    return x * 0x2545F4914F6CDD1Dull;
}
static uint32_t rnd(uint32_t lo, uint32_t hi) { /* inclusive */
    if (hi <= lo) return lo;
    return lo + (uint32_t)(rng_next() % (uint64_t)(hi - lo + 1));
}

/* ---- storage ---- */
static risk_cfg_t   cfg;
static risk_state_t st;
#define MAX_ORDERS 4096
static order_t    orders[MAX_ORDERS];
static decision_t golden[MAX_ORDERS];
static int        n_orders = 0;

static void push_order(uint16_t sym, uint16_t acct, uint8_t side,
                       uint32_t price, uint32_t qty) {
    if (n_orders >= MAX_ORDERS) return;
    order_t *o = &orders[n_orders];
    o->symbol   = sym;
    o->account  = acct;
    o->side     = side;
    o->price    = price;
    o->qty      = qty;
    o->order_id = (uint32_t)(0x100000u + n_orders);   /* unique tag */
    n_orders++;
}

static void build_config(void) {
    memset(&cfg, 0, sizeof(cfg));
    /* randomized baseline config for every symbol/account */
    for (int s = 0; s < SYM_N; s++) {
        uint32_t ref  = rnd(2000, 40000);
        uint32_t band = rnd(200, 1500);                 /* 2%..15% in bps */
        uint64_t lo = (uint64_t)ref * (10000 - band) / 10000;
        uint64_t hi = (uint64_t)ref * (10000 + band) / 10000;
        cfg.sym[s].price_lo     = (uint32_t)lo;
        cfg.sym[s].price_hi     = (uint32_t)hi;
        cfg.sym[s].max_qty      = rnd(2000, 20000);
        cfg.sym[s].max_notional = (uint64_t)hi * rnd(500, 4000);
        cfg.sym[s].enabled      = (rnd(0, 99) < 90) ? 1 : 0;  /* ~10% halted */
    }
    for (int a = 0; a < ACCT_N; a++) {
        cfg.acct[a].pos_limit = rnd(50000, 2000000);
        cfg.acct[a].max_msgs  = rnd(20, 400);
        cfg.acct[a].enabled   = (rnd(0, 99) < 92) ? 1 : 0;
    }
    /* ---- pin symbols/accounts 0..3 so the directed prefix is exact ---- */
    cfg.sym[0] = (sym_cfg_t){ .price_lo=1000, .price_hi=1100, .max_qty=500,
                              .max_notional=400000, .enabled=1 };
    cfg.sym[1] = (sym_cfg_t){ .price_lo=1, .price_hi=1000000000u,
                              .max_qty=1000000000u,
                              .max_notional=1000000000000000ull, .enabled=0 };
    cfg.acct[0] = (acct_cfg_t){ .pos_limit=100000, .max_msgs=1000000, .enabled=1 };
    cfg.acct[1] = (acct_cfg_t){ .pos_limit=100000, .max_msgs=3,       .enabled=1 };
    cfg.acct[2] = (acct_cfg_t){ .pos_limit=100000, .max_msgs=1000000, .enabled=0 };
    cfg.acct[3] = (acct_cfg_t){ .pos_limit=300,    .max_msgs=1000000, .enabled=1 };
    cfg.kill_switch = 0;
}

/* directed prefix: one order per rejection reason (2..8) plus accepts */
static void build_directed(void) {
    push_order(0, 0, SIDE_BUY, 2000, 10);   /* [0] PRICEBAND: price>hi   */
    push_order(9999, 0, SIDE_BUY, 1050, 10);/* [1] RANGE: symbol >= SYM_N */
    push_order(1, 0, SIDE_BUY, 500, 10);    /* [2] HALT: symbol disabled  */
    push_order(0, 2, SIDE_BUY, 1050, 10);   /* [3] HALT: account disabled */
    push_order(0, 0, SIDE_BUY, 1050, 0);    /* [4] MAXQTY: qty == 0       */
    push_order(0, 0, SIDE_BUY, 1050, 9999); /* [5] MAXQTY: qty > max      */
    push_order(0, 0, SIDE_BUY, 1050, 400);  /* [6] NOTIONAL: 420000>400000*/
    push_order(0, 3, SIDE_BUY, 1000, 400);  /* [7] POSLIMIT: 400>300      */
    push_order(0, 1, SIDE_BUY, 1050, 100);  /* [8] accept                 */
    push_order(0, 1, SIDE_BUY, 1050, 100);  /* [9] accept                 */
    push_order(0, 1, SIDE_BUY, 1050, 100);  /* [10] accept (3rd)          */
    push_order(0, 1, SIDE_BUY, 1050, 100);  /* [11] MSGCOUNT: 4th > 3     */
}

static void build_random(int nrand) {
    for (int i = 0; i < nrand; i++) {
        uint16_t sym  = (rnd(0, 99) < 6) ? (uint16_t)rnd(SYM_N, SYM_N + 8)
                                         : (uint16_t)rnd(0, SYM_N - 1);
        uint16_t acct = (rnd(0, 99) < 4) ? (uint16_t)rnd(ACCT_N, ACCT_N + 2)
                                         : (uint16_t)rnd(0, ACCT_N - 1);
        uint8_t  side = (uint8_t)rnd(0, 1);
        uint32_t price, qty;

        if (sym < SYM_N) {
            /* config-aware: mostly in-band so accepts, positions, and the
               per-account message cap all get exercised, with a healthy tail
               of every violation kind */
            uint32_t lo = cfg.sym[sym].price_lo, hi = cfg.sym[sym].price_hi;
            int roll = rnd(0, 99);
            if (roll < 12)      price = rnd(1, lo ? lo - 1 : 1);       /* below */
            else if (roll < 24) price = rnd(hi + 1, hi + hi / 2 + 2);  /* above */
            else                price = rnd(lo, hi);                   /* in    */

            /* qty ceiling that keeps notional under the cap for accepts */
            uint32_t nq = (uint32_t)(cfg.sym[sym].max_notional /
                                     (price ? price : 1));
            uint32_t qmax = cfg.sym[sym].max_qty;
            if (nq < qmax) qmax = nq;
            if (qmax < 1)  qmax = 1;
            int qroll = rnd(0, 99);
            if (qroll < 8)       qty = 0;                       /* zero      */
            else if (qroll < 20) qty = rnd(qmax + 1, qmax * 3 + 4); /* oversize */
            else                 qty = rnd(1, qmax);            /* valid     */
        } else {
            price = rnd(1000, 45000);
            qty   = rnd(1, 6000);
        }
        push_order(sym, acct, side, price, qty);
    }
}

int main(int argc, char **argv) {
    int nrand = 300;
    const char *outdir = "vectors";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--nrand") && i + 1 < argc) nrand = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc)
            rng_s = strtoull(argv[++i], NULL, 0) ^ 0x0BADC0DE12345678ull;
        else if (!strcmp(argv[i], "--outdir") && i + 1 < argc) outdir = argv[++i];
    }
    if (nrand > MAX_ORDERS - 32) nrand = MAX_ORDERS - 32;

    build_config();
    build_directed();
    build_random(nrand);

    /* ---- run the golden model over the whole stream from clean state ---- */
    risk_reset_state(&st);
    for (int i = 0; i < n_orders; i++)
        risk_eval(&cfg, &st, &orders[i], &golden[i]);

    long base_cycles = risk_baseline_cycles(&cfg, orders, n_orders);

    char path[512];
    FILE *f;

    /* ---- config.hex : APB writes that program the tables ---- */
    snprintf(path, sizeof(path), "%s/config.hex", outdir);
    f = fopen(path, "w");
    for (int s = 0; s < SYM_N; s++) {
        unsigned b = SYM_TBL_BASE + s * SYM_STRIDE;
        fprintf(f, "%03X %08X\n", b + 0x00, cfg.sym[s].price_lo);
        fprintf(f, "%03X %08X\n", b + 0x04, cfg.sym[s].price_hi);
        fprintf(f, "%03X %08X\n", b + 0x08, cfg.sym[s].max_qty);
        fprintf(f, "%03X %08X\n", b + 0x0C, (uint32_t)(cfg.sym[s].max_notional));
        fprintf(f, "%03X %08X\n", b + 0x10, (uint32_t)(cfg.sym[s].max_notional >> 32));
        fprintf(f, "%03X %08X\n", b + 0x14, cfg.sym[s].enabled ? 1u : 0u);
    }
    for (int a = 0; a < ACCT_N; a++) {
        unsigned b = ACCT_TBL_BASE + a * ACCT_STRIDE;
        fprintf(f, "%03X %08X\n", b + 0x00, cfg.acct[a].pos_limit);
        fprintf(f, "%03X %08X\n", b + 0x04, cfg.acct[a].max_msgs);
        fprintf(f, "%03X %08X\n", b + 0x08, cfg.acct[a].enabled ? 1u : 0u);
    }
    fclose(f);

    /* ---- orders.hex : 128-bit ingress beats ----
       layout: [15:0]sym [31:16]acct [63:32]price [95:64]qty
               [119:96]order_id [120]side  ->  word3 holds order_id+side */
    snprintf(path, sizeof(path), "%s/orders.hex", outdir);
    f = fopen(path, "w");
    for (int i = 0; i < n_orders; i++) {
        order_t *o = &orders[i];
        uint32_t w0 = ((uint32_t)o->symbol) | ((uint32_t)o->account << 16);
        uint32_t w1 = o->price;
        uint32_t w2 = o->qty;
        uint32_t w3 = (o->order_id & 0x00FFFFFFu) | ((uint32_t)(o->side & 1) << 24);
        fprintf(f, "%08X%08X%08X%08X\n", w3, w2, w1, w0);
    }
    fclose(f);

    /* ---- golden.txt ---- */
    snprintf(path, sizeof(path), "%s/golden.txt", outdir);
    f = fopen(path, "w");
    for (int i = 0; i < n_orders; i++) {
        decision_t *d = &golden[i];
        fprintf(f, "%u %u %u %u %u %d\n",
                d->order_id, d->accept, d->reason, d->symbol, d->account, d->out_pos);
    }
    fclose(f);

    /* ---- risk_const.vh ---- */
    snprintf(path, sizeof(path), "%s/risk_const.vh", outdir);
    f = fopen(path, "w");
    fprintf(f, "`define NUM_ORDERS %d\n", n_orders);
    fprintf(f, "`define CFG_SYM_N  %d\n", SYM_N);
    fprintf(f, "`define CFG_ACCT_N %d\n", ACCT_N);
    fprintf(f, "`define ANCHOR_REASON %d\n", REJ_PRICEBAND);
    fprintf(f, "`define EXP_TOTAL  %u\n", st.total);
    fprintf(f, "`define EXP_ACCEPT %u\n", st.accepted);
    fprintf(f, "`define EXP_REJECT %u\n", st.rejected);
    for (int r = 1; r <= 8; r++)
        fprintf(f, "`define EXP_REJ%d %u\n", r, st.rej[r]);
    fclose(f);

    /* ---- sw_metrics.txt ---- */
    snprintf(path, sizeof(path), "%s/sw_metrics.txt", outdir);
    f = fopen(path, "w");
    fprintf(f, "num_orders %d\n", n_orders);
    fprintf(f, "num_accept %u\n", st.accepted);
    fprintf(f, "num_reject %u\n", st.rejected);
    fprintf(f, "baseline_total_cycles %ld\n", base_cycles);
    fprintf(f, "baseline_cycles_per_order %.3f\n",
            n_orders ? (double)base_cycles / n_orders : 0.0);
    fclose(f);

    printf("risk_host: %d orders (12 directed + %d random), "
           "accept=%u reject=%u, baseline=%ld cyc\n",
           n_orders, nrand, st.accepted, st.rejected, base_cycles);
    return 0;
}
