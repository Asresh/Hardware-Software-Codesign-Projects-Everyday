/* ============================================================================
 * kvp_baseline.c - scalar software-only cost model for KV-cache paging.
 *
 * What a single CPU core must do per translation when there is no paging engine:
 * build the (seq, logical) key, probe a software translation cache, promote the
 * LRU order, and on a miss walk the block table in memory, allocate a physical
 * block from the free stack and install the entry.  The model charges one cycle
 * per modelled operation and is deliberately generous to the CPU:
 *
 *   - a block-table load costs 1 cycle, not the tens of cycles a real
 *     last-level-cache miss to a multi-megabyte block table would cost;
 *   - loop overhead, branch mispredicts and the atomics a real serving runtime
 *     needs around a shared block pool are all free;
 *   - the request/result loads and stores are charged once, flat.
 *
 * So the measured speedup is a conservative lower bound.
 *
 *   C_REQ   4   fetch the request word, extract op / seq / arg
 *   C_PROBE 12  build the key (4) + scan the indexed set's tags (8)
 *   C_HITX  7   load the physical block + move-to-front the LRU order
 *   C_WALK  5   seq*stride + base (3), load the entry (1), test invalid (1)
 *   C_FILL  15  victim scan (6) + store tag/phys/valid (3) + move-to-front (6)
 *   C_ALLOC 8   load stack pointer, load block, store pointer, store entry, test
 *   C_RES   2   form the result word and store it
 *   C_FREEB 12  load entry, test, push block (3), invalidate cache entry (6),
 *               store the poison value
 * ==========================================================================*/
#include "kvp.h"

#define C_REQ   4u
#define C_PROBE 12u
#define C_HITX  7u
#define C_WALK  5u
#define C_FILL  15u
#define C_ALLOC 8u
#define C_RES   2u
#define C_FREEB 12u

uint64_t kvp_baseline_cycles(uint64_t reqs, uint64_t hits, uint64_t misses,
                             uint64_t allocs, uint64_t frees)
{
    uint64_t miss_valid = (misses > allocs) ? (misses - allocs) : 0;

    uint64_t c_hit   = C_PROBE + C_HITX + C_RES;              /* 21 */
    uint64_t c_mv    = C_PROBE + C_WALK + C_FILL + C_RES;     /* 34 */
    uint64_t c_alloc = C_PROBE + C_WALK + C_ALLOC + C_FILL + C_RES; /* 42 */

    return reqs * C_REQ
         + hits * c_hit
         + miss_valid * c_mv
         + allocs * c_alloc
         + frees * C_FREEB;
}

void kvp_baseline_terms(FILE *f)
{
    fprintf(f, "baseline_c_req %u\n",   C_REQ);
    fprintf(f, "baseline_c_hit %u\n",   C_PROBE + C_HITX + C_RES);
    fprintf(f, "baseline_c_miss %u\n",  C_PROBE + C_WALK + C_FILL + C_RES);
    fprintf(f, "baseline_c_alloc %u\n", C_PROBE + C_WALK + C_ALLOC + C_FILL + C_RES);
    fprintf(f, "baseline_c_freeblk %u\n", C_FREEB);
}
