/* ==========================================================================
 * asig_baseline.c - scalar software-only baseline cost model.
 *
 * The baseline is an in-order scalar core that recomputes the SAME signal per
 * tick with no streaming pipeline: it pays the latency of a native integer
 * multiply, a hardware square root and a hardware divide on every tick, plus
 * the surrounding add/shift/compare work.  Per-op latencies are stated here so
 * the speedup in the README is a documented model, not a magic number.  The
 * accelerator retires one tick per clock, so hw_cycles ~= ticks (+ pipe drain).
 * ========================================================================== */
#include "asig.h"

/* documented scalar per-op latencies (cycles) */
#define L_ALU    1     /* add / sub / shift / compare / mask */
#define L_MUL    3     /* integer multiply                   */
#define L_SQRT  18     /* hardware square root               */
#define L_DIV   22     /* hardware integer divide            */

/* cost of one steady-state tick (count > 0) */
static uint64_t tick_cost_steady(void)
{
    uint64_t c = 0;
    c += L_ALU + L_MUL + L_ALU + L_ALU;        /* ewma_fast update */
    c += L_ALU + L_MUL + L_ALU + L_ALU;        /* ewma_slow update */
    c += L_ALU + L_MUL + L_ALU;                /* deviation, square */
    c += L_ALU + L_MUL + L_ALU + L_ALU;        /* variance update  */
    c += L_ALU;                                /* dev vs slow      */
    c += L_ALU + L_SQRT;                       /* std = sqrt(var)  */
    c += L_ALU + L_DIV + L_ALU + L_ALU;        /* z = dev/std + sat */
    c += L_ALU;                                /* momentum         */
    c += 6 * L_ALU;                            /* flag compares    */
    c += 8 * L_ALU;                            /* load/store/loop  */
    return c;
}

/* cost of the seeding tick (count == 0): just initialise and emit */
static uint64_t tick_cost_seed(void)
{
    return 4 * L_ALU          /* seed ewma/var/count */
         + L_ALU + L_SQRT     /* std (of zero)       */
         + 8 * L_ALU;         /* flags + store/loop  */
}

/* total scalar cycles to process a corpus given, per symbol, how many ticks it
 * received (the first tick per symbol is a seed).  n_ticks is the flat total,
 * n_seeds is the number of distinct symbols that appear at least once. */
uint64_t asig_baseline_cycles(uint64_t n_ticks, uint64_t n_seeds)
{
    uint64_t steady = (n_ticks >= n_seeds) ? (n_ticks - n_seeds) : 0;
    return n_seeds * tick_cost_seed() + steady * tick_cost_steady();
}
