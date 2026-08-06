/* ===========================================================================
 * kds_baseline.c - the software-only scheduler this accelerator replaces.
 *
 * A CPU driving the same graph on the same devices has to do the scheduling
 * itself, and while it is doing that the devices are idle. This is a simulator
 * of exactly that: it runs the identical placement policy as kds_model.c, but
 * every readiness test, every completion poll and every launch costs the CPU
 * real cycles, and the device countdowns advance by those cycles.
 *
 * Every term is counted as it happens (ops_scan / ops_poll / ops_launch /
 * ops_load) and multiplied by a documented per-operation cost from kds.h - no
 * number here is a guess about the whole loop, only about one instruction
 * sequence:
 *
 *   KDS_C_LOAD      4                 load one graph word
 *   KDS_C_SCAN_NODE 4 + 2*DEPW        visit one node in a readiness scan:
 *                                     load the dep words, AND-NOT the done
 *                                     mask, compare, branch
 *   KDS_C_POLL_DEV  6                 read one device's completion flag
 *   KDS_C_LAUNCH    120               build a launch record and ring a
 *                                     doorbell (a real CUDA launch is
 *                                     microseconds; 120 cycles is deliberately
 *                                     charitable to the CPU)
 *
 * The scheduler observes completions only when it polls, which is what a
 * software runtime actually does, and it holds the device state it read at the
 * start of a round for the whole round.
 * ===========================================================================
 */
#include <string.h>
#include "kds.h"

#define BITSET(m, i)  ((m)[(i) >> 5] |= (1u << ((i) & 31)))
#define BITGET(m, i)  (((m)[(i) >> 5] >> ((i) & 31)) & 1u)

static int lowest_set(uint32_t m)
{
    int i;
    for (i = 0; i < 32; i++)
        if (m & (1u << i)) return i;
    return -1;
}

int kds_baseline(const kds_node_t *nd, int n, kds_base_t *b)
{
    uint32_t done[KDS_DEPW], issued[KDS_DEPW];
    int      busy[KDS_DEVICES], unode[KDS_DEVICES];
    uint32_t rem[KDS_DEVICES];
    uint32_t now;
    int      dcount = 0, i, u, w;

    memset(b, 0, sizeof *b);
    if (n < 1 || n > KDS_MAX_NODES) return -1;

    memset(done, 0, sizeof done);
    memset(issued, 0, sizeof issued);
    for (u = 0; u < KDS_DEVICES; u++) { busy[u] = 0; rem[u] = 0; unode[u] = 0; }

    /* the runtime has to read the graph before it can schedule it */
    b->ops_load = (uint64_t)n * KDS_NODE_WORDS;
    now         = (uint32_t)(b->ops_load * KDS_C_LOAD);

    while (dcount < n) {
        uint32_t cost = 0, freem = 0;
        int sel = -1, su = -1;

        /* --- poll every device; a device that has already elapsed is only
               noticed here, which is the polling latency a runtime pays --- */
        for (u = 0; u < KDS_DEVICES; u++) {
            cost += KDS_C_POLL_DEV;
            b->ops_poll++;
            if (busy[u] && rem[u] == 0) {
                busy[u] = 0;
                BITSET(done, unode[u]);
                dcount++;
            }
        }
        if (dcount == n) { now += cost; b->rounds++; break; }

        for (u = 0; u < KDS_DEVICES; u++)
            if (!busy[u]) freem |= (1u << u);

        /* --- readiness scan, charged per node visited, stopping at the
               first node it can actually place ---------------------------- */
        for (i = 0; i < n; i++) {
            int rdy = 1;
            if (BITGET(issued, i)) continue;
            cost += KDS_C_SCAN_NODE;
            b->ops_scan++;
            for (w = 0; w < KDS_DEPW; w++)
                if (nd[i].dep[w] & ~done[w]) { rdy = 0; break; }
            if (!rdy) continue;
            if (nd[i].dev & freem) {
                sel = i;
                su  = lowest_set((uint32_t)nd[i].dev & freem);
                break;
            }
        }

        if (sel >= 0) { cost += KDS_C_LAUNCH; b->ops_launch++; }

        /* --- time passes: the devices run, the CPU does not watch them --- */
        for (u = 0; u < KDS_DEVICES; u++) {
            if (busy[u]) rem[u] = (rem[u] > cost) ? (rem[u] - cost) : 0u;
            else         b->idle_dev_ticks += cost;
        }
        now += cost;
        b->rounds++;

        if (sel >= 0) {
            busy[su]  = 1;
            rem[su]   = nd[sel].dur;
            unode[su] = sel;
            BITSET(issued, sel);
        }
    }

    b->cycles = now;
    return 0;
}
