/* ---------------------------------------------------------------------------
 * sort_baseline.c
 * Software-only tiled sort - the reference point the accelerator is measured
 * against - plus an explicit, conservative cycle model.
 *
 * The baseline does the same work the accelerator does: sort every contiguous
 * N-key tile. On a scalar in-order core a comparison sort of N keys is a chain
 * of key comparisons, each of which stalls the next when it feeds a conditional
 * move. The model (see sort_accel.h) charges SORT_CPC cycles per comparison and
 * only ~N*ceil(log2(N)) comparisons per tile - the merge-sort lower bound. Real
 * sorts do more (recursion, pivots, branch misprediction), so the model
 * under-counts software cost and never inflates the reported speedup.
 * ------------------------------------------------------------------------- */
#include "sort_accel.h"

/* An in-place insertion sort of one N-key tile: small, branch-simple, and a
 * faithful stand-in for what a scalar core does on a warp-sized key set. */
static void tile_sort(uint32_t *a, int descending)
{
    for (uint32_t i = 1; i < SORT_N; i++) {
        uint32_t key = a[i];
        int32_t  j   = (int32_t)i - 1;
        if (descending)
            while (j >= 0 && a[j] < key) { a[j + 1] = a[j]; j--; }
        else
            while (j >= 0 && a[j] > key) { a[j + 1] = a[j]; j--; }
        a[j + 1] = key;
    }
}

void sort_baseline(const uint32_t *in, uint32_t *out, uint32_t ntiles, int descending)
{
    for (uint32_t t = 0; t < ntiles; t++) {
        uint32_t *dst = out + (size_t)t * SORT_N;
        for (uint32_t k = 0; k < SORT_N; k++)
            dst[k] = in[(size_t)t * SORT_N + k];
        tile_sort(dst, descending);
    }
}

uint64_t sort_baseline_cycles(uint32_t ntiles)
{
    return (uint64_t)SORT_CPT * (uint64_t)ntiles;
}
