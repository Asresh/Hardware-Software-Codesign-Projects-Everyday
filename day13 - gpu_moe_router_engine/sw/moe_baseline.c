/* ============================================================================
 * moe_baseline.c - scalar CPU cost model for MoE top-k gating.
 *
 * A transparent, documented per-token cycle count for a scalar core running
 * the same routing math the accelerator does in hardware.  This is the honest
 * denominator for the speedup numbers; it is a cost *model*, not a measured
 * CPU run, and every term is spelled out so the estimate can be audited.
 * ==========================================================================*/
#include "moe.h"

/* Modelled per-operation scalar costs (cycles) for a simple in-order core. */
#define C_CMP   1     /* integer compare / branch                            */
#define C_ADD   1     /* integer add                                         */
#define C_EXP  20     /* softmax exp() (polynomial / library, per call)      */
#define C_DIV  30     /* integer/fixed-point divide (renormalise)            */
#define C_MEM   3     /* load/store of a per-expert counter                  */

long moe_baseline_cycles_per_token(void)
{
    long c = 0;

    /* top-K selection: K passes of a linear argmax over E logits            */
    c += (long)MOE_K * (MOE_E - 1) * C_CMP;

    /* exp() for each of the K selected experts + running denominator add    */
    c += (long)MOE_K * C_EXP;
    c += (long)(MOE_K - 1) * C_ADD;

    /* renormalise: one fixed-point divide per selected expert               */
    c += (long)MOE_K * C_DIV;

    /* capacity check + counter read-modify-write per selected expert        */
    c += (long)MOE_K * (C_MEM + C_CMP + C_ADD + C_MEM);

    return c;
}
