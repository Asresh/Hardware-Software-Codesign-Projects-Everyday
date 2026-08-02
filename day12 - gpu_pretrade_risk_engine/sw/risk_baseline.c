/* ===========================================================================
 * risk_baseline.c - scalar CPU cost model for the software-only risk check.
 *
 * A documented, honest instruction-count model of what a straightforward
 * single-threaded firmware risk gate costs per order on a scalar core at
 * ~1 IPC: unpack, two config lookups, a keyed position-map load, the six
 * comparison gates (each a compare + a mispredictable branch), a 64-bit
 * notional multiply, and the accepted-order stores. It is deliberately
 * conservative - no SIMD, no pipelining - so the hardware speedup is a
 * like-for-like "same work, one engine" comparison.
 * ===========================================================================
 */
#include "risk.h"

/* fixed per-order op budget (see README for the line-by-line derivation) */
#define BASE_OPS        45   /* unpack + 2 lookups + 6 gates + priority     */
#define ACCEPT_STORES    2   /* position + count store-back on accept       */
#define BRANCH_PENALTY  12   /* pipeline flush on a mispredicted gate branch */

/* Return the modeled scalar-core cycle cost of running the whole order
 * stream through a software risk check. A rejected order costs one extra
 * mispredicted branch (the reject path is the unlikely one the compiler
 * predicts not-taken). */
long risk_baseline_cycles(const risk_cfg_t *cfg, const order_t *orders, int n) {
    /* replay the same gates on a private copy of the state so the cost
     * tracks the real accept/reject mix, then throw the state away */
    static risk_state_t st;
    risk_reset_state(&st);
    long cycles = 0;
    for (int i = 0; i < n; i++) {
        decision_t d;
        risk_eval(cfg, &st, &orders[i], &d);
        cycles += BASE_OPS;
        if (d.accept) cycles += ACCEPT_STORES;
        else          cycles += BRANCH_PENALTY;   /* reject = mispredict */
    }
    return cycles;
}
