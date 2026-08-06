/* ===========================================================================
 * kds_model.c - golden model of the scheduler core.
 *
 * This is a tick-by-tick mirror of the RUN phase of rtl/kds_core.v, written
 * so that the two can be compared bit for bit: same readiness rule, same
 * placement rule, same tie-break, same completion timing, same counters.
 *
 * Semantics of one tick (everything below reads the state as it stands at the
 * START of the tick and commits at the end of it, exactly like a flop):
 *
 *   ready[i]      = !issued[i] && (dep[i] & ~done) == 0        (i < n)
 *   free          = devices whose slot is idle
 *   placeable[i]  = ready[i] && (dev[i] & free) != 0
 *   dispatch      = lowest-indexed placeable node, onto its lowest-indexed
 *                   allowed free device
 *   a device with rem == 0 retires its node at the end of the tick: the done
 *   bit and the freed slot are both visible on the NEXT tick, so
 *       finish = start + duration + 1
 *   and a node occupies its device for duration + 1 ticks (one issue cycle
 *   plus `duration` execution ticks).
 *
 * The invariants the testbench checks fall straight out of that:
 *   sum(dev_busy)  == sum over nodes of (duration + 1) == serial_ticks
 *   makespan       == dispatched + stall_ticks + depwait_ticks
 * ===========================================================================
 */
#include <string.h>
#include "kds.h"

#define BITSET(m, i)  ((m)[(i) >> 5] |= (1u << ((i) & 31)))
#define BITGET(m, i)  (((m)[(i) >> 5] >> ((i) & 31)) & 1u)

/* a runaway graph would hang the model; the RTL has the same guard */
#define KDS_TICK_LIMIT 0x00400000u

static int lowest_set(uint32_t m)
{
    int i;
    for (i = 0; i < 32; i++)
        if (m & (1u << i)) return i;
    return -1;
}

int kds_model(const kds_node_t *nd, int n, kds_result_t *r)
{
    uint32_t done[KDS_DEPW], issued[KDS_DEPW];
    uint32_t devall = (KDS_DEVICES >= 32) ? 0xffffffffu : ((1u << KDS_DEVICES) - 1u);
    int      busy[KDS_DEVICES];
    uint32_t rem[KDS_DEVICES];
    int      unode[KDS_DEVICES];
    int      bad_dur = 0, bad_dev = 0, bad_dep = 0;
    uint32_t t = 0;
    int      dcount = 0, seq = 0, i, u, w;

    memset(r, 0, sizeof *r);

    if (n < 1 || n > KDS_MAX_NODES) {
        r->err = KDS_ERR_LEN;
        return r->err;
    }

    /* ---- CHECK phase: every node is validated as its record lands ------- */
    for (i = 0; i < n; i++) {
        if (nd[i].dur == 0)                          bad_dur = 1;
        if (nd[i].dev == 0 || (nd[i].dev & ~devall)) bad_dev = 1;
        if (BITGET(nd[i].dep, i))                    bad_dep = 1;
        for (w = 0; w < KDS_DEPW; w++) {
            uint32_t lim;                            /* bits belonging to a
                                                        node index >= n      */
            if ((w + 1) * 32 <= n)      lim = 0u;
            else if (w * 32 >= n)       lim = 0xffffffffu;
            else                        lim = ~((1u << (n - w * 32)) - 1u);
            if (nd[i].dep[w] & lim)                  bad_dep = 1;
        }
        r->serial_ticks += (uint32_t)nd[i].dur + 1u;
    }
    /* fixed priority, so the reported code never depends on scan order */
    if (bad_dur)      { r->err = KDS_ERR_DUR; return r->err; }
    if (bad_dev)      { r->err = KDS_ERR_DEV; return r->err; }
    if (bad_dep)      { r->err = KDS_ERR_DEP; return r->err; }

    /* ---- RUN phase ------------------------------------------------------ */
    memset(done, 0, sizeof done);
    memset(issued, 0, sizeof issued);
    for (u = 0; u < KDS_DEVICES; u++) { busy[u] = 0; rem[u] = 0; unode[u] = 0; }

    for (;;) {
        uint32_t freem = 0, occ;
        int sel = -1, su = -1, ready_any = 0, conc = 0;

        if (dcount == n) break;                       /* graph retired       */
        if (t >= KDS_TICK_LIMIT) { r->err = KDS_ERR_CYCLE; return r->err; }

        for (u = 0; u < KDS_DEVICES; u++)
            if (!busy[u]) freem |= (1u << u);

        for (i = 0; i < n; i++) {
            int rdy = 1;
            if (BITGET(issued, i)) continue;
            for (w = 0; w < KDS_DEPW; w++)
                if (nd[i].dep[w] & ~done[w]) { rdy = 0; break; }
            if (!rdy) continue;
            ready_any = 1;
            if (sel < 0 && (nd[i].dev & freem))
                { sel = i; su = lowest_set((uint32_t)nd[i].dev & freem); }
        }

        /* nothing runnable and nothing running -> the graph has a cycle */
        if (sel < 0 && freem == devall) { r->err = KDS_ERR_CYCLE; return r->err; }

        /* --- statistics for this tick (device occupancy includes the issue
               cycle, so occupancy per node is exactly duration + 1) ------- */
        occ = (~freem) & devall;
        if (sel >= 0) occ |= (1u << su);
        for (u = 0; u < KDS_DEVICES; u++)
            if (occ & (1u << u)) { r->dev_busy[u]++; conc++; }
        if ((uint32_t)conc > r->max_conc) r->max_conc = (uint32_t)conc;
        if (sel >= 0)              r->dispatched++;
        else if (ready_any)        r->stall_ticks++;
        else                       r->depwait_ticks++;

        /* --- commit: retirements first, then the dispatch. A retiring
               device is busy, hence never a dispatch target this tick. --- */
        for (u = 0; u < KDS_DEVICES; u++) {
            if (!busy[u]) continue;
            if (rem[u] == 0) {
                busy[u] = 0;
                BITSET(done, unode[u]);
                r->finish[unode[u]] = t + 1u;
                dcount++;
            } else {
                rem[u]--;
            }
        }
        if (sel >= 0) {
            busy[su]     = 1;
            rem[su]      = (uint32_t)nd[sel].dur - 1u;
            unode[su]    = sel;
            BITSET(issued, sel);
            r->start[sel] = t;
            r->dev[sel]   = (uint8_t)su;
            r->seq[sel]   = (uint16_t)seq++;
        }
        t++;
    }

    r->makespan = t;
    r->err      = KDS_ERR_NONE;
    return r->err;
}
