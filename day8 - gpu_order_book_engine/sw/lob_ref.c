/* =============================================================================
 * lob_ref.c - golden reference limit-order book.
 *
 * This models the *exact* semantics of the CAM hardware, not an idealised
 * book: a fixed pool of N_LEVELS slots, first-free allocation, drop-on-full
 * with a sticky overflow flag, and free-at-zero-quantity. BBO depends only on
 * the active {(side,price) -> qty} set (not on slot indices), and overflow
 * depends only on the active count, so this map-style model is bit-exactly
 * equivalent to the hardware slot array while being far easier to read.
 * ========================================================================== */
#include "lob.h"
#include <string.h>

typedef struct {
    int      valid;
    uint32_t side;
    uint32_t price;
    uint32_t qty;
} slot_t;

static slot_t book[N_LEVELS];
static int    overflow_sticky;

void lob_reset(void)
{
    memset(book, 0, sizeof(book));
    overflow_sticky = 0;
}

int lob_overflow(void) { return overflow_sticky; }

int lob_active(void)
{
    int n = 0;
    for (int i = 0; i < N_LEVELS; i++)
        if (book[i].valid) n++;
    return n;
}

/* find the slot matching (side,price); -1 if none */
static int find_slot(uint32_t side, uint32_t price)
{
    for (int i = 0; i < N_LEVELS; i++)
        if (book[i].valid && book[i].side == side && book[i].price == price)
            return i;
    return -1;
}

/* first free slot; -1 if the book is full */
static int free_slot(void)
{
    for (int i = 0; i < N_LEVELS; i++)
        if (!book[i].valid) return i;
    return -1;
}

void lob_apply(const msg_t *m)
{
    uint32_t qmask = QTY_MASK;
    int hit = find_slot(m->side, m->price);

    if (hit >= 0) {
        uint32_t q = book[hit].qty;
        switch (m->op) {
        case OP_ADD: q = (q + m->qty) & qmask;                 break;
        case OP_SUB: q = (q > m->qty) ? (q - m->qty) : 0u;     break;
        case OP_SET: q = m->qty & qmask;                       break;
        case OP_CLR: q = 0u;                                   break;
        default: break;
        }
        book[hit].qty = q;
        if (q == 0u) book[hit].valid = 0;   /* free at zero quantity */
        return;
    }

    /* miss: only ADD / SET with a non-zero quantity can allocate a level */
    if ((m->op == OP_ADD || m->op == OP_SET) && (m->qty & qmask) != 0u) {
        int fs = free_slot();
        if (fs < 0) { overflow_sticky = 1; return; }   /* full -> drop */
        book[fs].valid = 1;
        book[fs].side  = m->side;
        book[fs].price = m->price;
        book[fs].qty   = m->qty & qmask;
    }
    /* SUB / CLR on a miss, or ADD/SET of zero: no-op */
}

void lob_bbo(bbo_t *out)
{
    memset(out, 0, sizeof(*out));
    for (int i = 0; i < N_LEVELS; i++) {
        if (!book[i].valid) continue;
        if (book[i].side == SIDE_BID) {
            if (!out->bid_valid || book[i].price > out->bid_price) {
                out->bid_valid = 1;
                out->bid_price = book[i].price;
                out->bid_qty   = book[i].qty;
            }
        } else {
            if (!out->ask_valid || book[i].price < out->ask_price) {
                out->ask_valid = 1;
                out->ask_price = book[i].price;
                out->ask_qty   = book[i].qty;
            }
        }
    }
}
