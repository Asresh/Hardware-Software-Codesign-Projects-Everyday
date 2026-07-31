/* =============================================================================
 * lob_baseline.c - scalar CPU cost model for a software limit-order book.
 *
 * The honest baseline a trader would run without the accelerator: an array of
 * active price levels, a linear search to find/allocate the level, and a linear
 * scan to recompute the best bid and best offer after every message. Both scans
 * are O(L) in the number of active levels L, which is exactly the cost the CAM
 * collapses to O(1).
 *
 * The cycle model charges a small fixed number of scalar-issue cycles per
 * primitive operation. It is a *model* (not a measured CPU trace); the
 * constants below are stated in the README so the speedup can be reproduced.
 *   - each level compared in a scan:            C_CMP  cycles
 *   - the found/allocated level update:         C_UPD  cycles
 *   - fixed per-message decode + dispatch:      C_FIX  cycles
 * BBO recompute scans every active level twice (bid test + ask test) folded
 * into one pass, so it costs L * C_CMP as well.
 * ========================================================================== */
#include "lob.h"

#define C_CMP 2u    /* load level + compare (side/price) per scanned entry   */
#define C_UPD 4u    /* arithmetic + store on the matched/allocated level     */
#define C_FIX 6u    /* per-message decode, branch, bookkeeping               */

typedef struct { int valid; uint32_t side, price, qty; } bslot_t;

void lob_baseline_stats(const msg_t *msgs, int n,
                        uint64_t *total, uint64_t *peak_permsg)
{
    static bslot_t book[N_LEVELS];
    for (int i = 0; i < N_LEVELS; i++) book[i].valid = 0;

    uint64_t cycles = 0, peak = 0;
    uint32_t qmask = QTY_MASK;

    for (int k = 0; k < n; k++) {
        const msg_t *m = &msgs[k];
        uint64_t before = cycles;
        cycles += C_FIX;

        /* ---- find (linear search over active levels) ---- */
        int hit = -1;
        for (int i = 0; i < N_LEVELS; i++) {
            if (!book[i].valid) continue;
            cycles += C_CMP;
            if (book[i].side == m->side && book[i].price == m->price) { hit = i; }
        }

        if (hit >= 0) {
            uint32_t q = book[hit].qty;
            switch (m->op) {
            case OP_ADD: q = (q + m->qty) & qmask;             break;
            case OP_SUB: q = (q > m->qty) ? (q - m->qty) : 0u; break;
            case OP_SET: q = m->qty & qmask;                   break;
            case OP_CLR: q = 0u;                               break;
            }
            book[hit].qty = q;
            if (q == 0u) book[hit].valid = 0;
            cycles += C_UPD;
        } else if ((m->op == OP_ADD || m->op == OP_SET) && (m->qty & qmask) != 0u) {
            int fs = -1;
            for (int i = 0; i < N_LEVELS; i++) {          /* find free slot */
                cycles += C_CMP;
                if (!book[i].valid) { fs = i; break; }
            }
            if (fs >= 0) {
                book[fs].valid = 1; book[fs].side = m->side;
                book[fs].price = m->price; book[fs].qty = m->qty & qmask;
                cycles += C_UPD;
            }
        }

        /* ---- recompute BBO (single fused scan over active levels) ---- */
        for (int i = 0; i < N_LEVELS; i++) {
            if (!book[i].valid) continue;
            cycles += C_CMP;
        }

        uint64_t permsg = cycles - before;
        if (permsg > peak) peak = permsg;
    }
    if (total)       *total = cycles;
    if (peak_permsg) *peak_permsg = peak;
}

uint64_t lob_baseline_cycles(const msg_t *msgs, int n)
{
    uint64_t total = 0;
    lob_baseline_stats(msgs, n, &total, 0);
    return total;
}
