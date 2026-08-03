/* ============================================================================
 * arc_baseline.c - scalar CPU cost model for an all-reduce reduction.
 *
 * A transparent, documented per-element cycle count for a scalar core folding
 * R rank buffers element-wise into a destination buffer - the honest speedup
 * denominator.  This is a cost *model*, not a measured CPU run, and every term
 * is spelled out so the estimate can be audited.
 * ==========================================================================*/
#include "arc.h"

/* Modelled per-operation scalar costs (cycles) on a simple in-order core.    */
#define C_MEM 3     /* load / store of one rank element (cache-hit)           */
#define C_OP  1     /* one reduction op (add / mul / compare-select)          */

long arc_baseline_cycles_per_element(int r)
{
    long c = 0;
    c += (long)r * C_MEM;          /* load one element from each of R ranks   */
    c += (long)(r - 1) * C_OP;     /* R-1 reductions to fold them             */
    c += C_MEM;                    /* store the reduced result                */
    return c;
}
