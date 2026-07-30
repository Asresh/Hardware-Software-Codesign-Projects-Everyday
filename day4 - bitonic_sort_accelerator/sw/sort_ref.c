/* ---------------------------------------------------------------------------
 * sort_ref.c
 * Software golden model: sorts each contiguous N-key tile independently, the
 * same segmentation and key-only ordering the bitonic network performs. Every
 * checked output word must match this bit-for-bit.
 *
 * Keys are unsigned 32-bit, compared exactly as the hardware comparators do.
 * The sort within a tile need not be stable (keys carry no payload), so a plain
 * comparison sort is a valid oracle for a bitonic network's output.
 * ------------------------------------------------------------------------- */
#include "sort_accel.h"

static int cmp_asc(const void *a, const void *b)
{
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x < y) ? -1 : (x > y) ? 1 : 0;
}
static int cmp_desc(const void *a, const void *b)
{
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x > y) ? -1 : (x < y) ? 1 : 0;
}

#include <stdlib.h>
#include <string.h>

void sort_reference(const uint32_t *in, uint32_t *out, uint32_t ntiles, int descending)
{
    for (uint32_t t = 0; t < ntiles; t++) {
        uint32_t *dst = out + (size_t)t * SORT_N;
        memcpy(dst, in + (size_t)t * SORT_N, SORT_N * sizeof(uint32_t));
        qsort(dst, SORT_N, sizeof(uint32_t), descending ? cmp_desc : cmp_asc);
    }
}
