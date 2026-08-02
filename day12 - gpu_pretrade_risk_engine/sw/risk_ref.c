/* ===========================================================================
 * risk_ref.c - bit-exact golden reference for the pre-trade risk engine.
 *
 * risk_eval() applies the six risk gates in the exact priority order the
 * hardware priority encoder uses, mutates the position/count state only on a
 * full ACCEPT, and fills in the decision. Every arithmetic width here matches
 * the RTL (64-bit notional, 64-bit position intermediate) so the two agree to
 * the bit across every vector.
 * ===========================================================================
 */
#include "risk.h"
#include <string.h>

const char *reason_name(int r) {
    switch (r) {
        case REJ_NONE:      return "ACCEPT";
        case REJ_KILL:      return "KILL";
        case REJ_RANGE:     return "RANGE";
        case REJ_HALT:      return "HALT";
        case REJ_PRICEBAND: return "PRICEBAND";
        case REJ_MAXQTY:    return "MAXQTY";
        case REJ_NOTIONAL:  return "NOTIONAL";
        case REJ_POSLIMIT:  return "POSLIMIT";
        case REJ_MSGCOUNT:  return "MSGCOUNT";
        default:            return "?";
    }
}

void risk_reset_state(risk_state_t *st) {
    memset(st, 0, sizeof(*st));
}

static int64_t i64abs(int64_t x) { return x < 0 ? -x : x; }

void risk_eval(const risk_cfg_t *cfg, risk_state_t *st,
               const order_t *o, decision_t *d) {
    int reason = REJ_NONE;
    int32_t out_pos = 0;
    int64_t newpos  = 0;

    int in_range = (o->symbol < SYM_N) && (o->account < ACCT_N);

    /* condition bits (all evaluated; priority encoder resolves the winner) */
    int c_kill      = cfg->kill_switch ? 1 : 0;
    int c_range     = in_range ? 0 : 1;
    int c_halt = 0, c_price = 0, c_qty = 0, c_not = 0, c_pos = 0, c_msg = 0;

    if (in_range) {
        const sym_cfg_t  *s = &cfg->sym[o->symbol];
        const acct_cfg_t *a = &cfg->acct[o->account];
        int32_t  pos = st->pos[o->account * SYM_N + o->symbol];
        uint32_t cnt = st->count[o->account];
        uint64_t notional = (uint64_t)o->price * (uint64_t)o->qty;
        int64_t  sqty = (o->side == SIDE_SELL) ? -(int64_t)o->qty : (int64_t)o->qty;

        newpos  = (int64_t)pos + sqty;
        out_pos = pos;   /* default: unchanged (reject path) */

        c_halt  = (!s->enabled || !a->enabled) ? 1 : 0;
        c_price = (o->price < s->price_lo || o->price > s->price_hi) ? 1 : 0;
        c_qty   = (o->qty == 0 || o->qty > s->max_qty) ? 1 : 0;
        c_not   = (notional > s->max_notional) ? 1 : 0;
        c_pos   = (i64abs(newpos) > (int64_t)a->pos_limit) ? 1 : 0;
        c_msg   = ((uint64_t)cnt + 1 > (uint64_t)a->max_msgs) ? 1 : 0;
    }

    /* priority encode (lowest code wins) */
    if      (c_kill)  reason = REJ_KILL;
    else if (c_range) reason = REJ_RANGE;
    else if (c_halt)  reason = REJ_HALT;
    else if (c_price) reason = REJ_PRICEBAND;
    else if (c_qty)   reason = REJ_MAXQTY;
    else if (c_not)   reason = REJ_NOTIONAL;
    else if (c_pos)   reason = REJ_POSLIMIT;
    else if (c_msg)   reason = REJ_MSGCOUNT;
    else              reason = REJ_NONE;

    if (reason == REJ_NONE) {
        /* commit: update position and accepted-order count */
        st->pos[o->account * SYM_N + o->symbol] = (int32_t)newpos;
        st->count[o->account] += 1;
        out_pos = (int32_t)newpos;
    }

    d->order_id = o->order_id;
    d->accept   = (reason == REJ_NONE);
    d->reason   = (uint8_t)reason;
    d->symbol   = o->symbol;
    d->account  = (uint8_t)o->account;
    d->out_pos  = out_pos;

    /* aggregate stats */
    st->total++;
    if (d->accept) st->accepted++;
    else { st->rejected++; st->rej[reason]++; }
}
