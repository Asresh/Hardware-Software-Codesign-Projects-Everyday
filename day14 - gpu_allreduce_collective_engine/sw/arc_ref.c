/* ============================================================================
 * arc_ref.c - bit-exact golden model for one collective descriptor.
 *
 * Operates on the same flat word-addressable memory image the RTL testbench
 * loads, so the reference and the hardware read exactly the same descriptors
 * and source buffers and must agree bit-for-bit on the destination buffer.
 * ==========================================================================*/
#include "arc.h"

void arc_run_desc(uint32_t *mem, uint32_t desc_base, int r, int p)
{
    (void)p;                                    /* p only affects timing, not values */
    uint32_t ctrl = mem[desc_base + ARC_D_CTRL];
    if (!(ctrl & ARC_CTRL_VALID)) return;       /* invalid descriptor: no work        */

    int      op  = (int)(ctrl & ARC_CTRL_OP_MASK);
    uint32_t n   = mem[desc_base + ARC_D_N];
    if (n == 0) return;

    uint32_t dst = mem[desc_base + ARC_D_DST];
    uint32_t src[ARC_RMAX];
    int      i;
    for (i = 0; i < r; i++) src[i] = mem[desc_base + ARC_D_SRC0 + i];

    uint32_t v[ARC_RMAX];
    uint32_t e;
    for (e = 0; e < n; e++) {
        for (i = 0; i < r; i++) v[i] = mem[src[i] + e];
        mem[dst + e] = arc_reduce(op, v, r);
    }
}
