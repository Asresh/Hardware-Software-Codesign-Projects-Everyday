/* ============================================================================
 * ann_baseline.c - scalar software-only cost model for the ANN search.
 *
 * A single scalar core (one int8 MAC/cycle, no SIMD, no dedicated top-K
 * network) scoring the same shard.  The cost model is deliberately generous
 * to the CPU - it charges nothing for loads/stores or loop overhead - so the
 * measured speedup is a conservative lower bound on the hardware advantage.
 *
 *   L2 per dimension : subtract + multiply + accumulate = 3 ops
 *   IP per dimension : multiply + accumulate            = 2 ops
 *   per vector       : + a K-way top-K insertion scan   = ANN_K ops
 *
 * At one modelled op per cycle this is:
 *   cycles = n * (ANN_D * C_dim + ANN_K)
 * ==========================================================================*/
#include "ann.h"

uint64_t ann_baseline_cycles(int metric, int n)
{
    uint64_t c_dim = (metric == ANN_METRIC_L2) ? 3u : 2u;
    uint64_t per_vec = (uint64_t)ANN_D * c_dim + (uint64_t)ANN_K;
    return (uint64_t)n * per_vec;
}
