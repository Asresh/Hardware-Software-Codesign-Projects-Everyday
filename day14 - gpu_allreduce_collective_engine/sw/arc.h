/* ============================================================================
 * arc.h - shared definitions for the GPU multi-GPU all-reduce collective
 *         engine (arc = All-Reduce Collective).
 *
 * One header, four consumers: the reference model (arc_ref.c), the scalar
 * cost-model baseline (arc_baseline.c), the firmware driver (arc_driver.c) and
 * the host/vector generator (arc_host.c).  Every reduction op the RTL must
 * reproduce lives here so the golden model and the hardware are provably the
 * same integer arithmetic.
 *
 * The engine is the hardware behind an NCCL-style ring/all-reduce collective:
 * given R rank buffers of N int32 elements each, it reduces them element-wise
 * with one of {SUM, PROD, MAX, MIN} and scatters the result to a destination
 * buffer - the primitive that fuses gradients / activations across GPUs in
 * distributed training and heterogeneous inference.
 * ==========================================================================*/
#ifndef ARC_H
#define ARC_H

#include <stdint.h>

/* ---------------- design parameters (mirror the RTL parameters) ----------- */
#ifndef ARC_R
#define ARC_R 4            /* number of ranks reduced in parallel             */
#endif
#ifndef ARC_P
#define ARC_P 4            /* SIMD lane width (elements reduced per clock)    */
#endif

#define ARC_DW       32    /* element width (bits)                            */
#define ARC_DESC_W   16    /* descriptor size in 32-bit words (fixed stride)  */
#define ARC_RMAX     13    /* max ranks that fit in one 16-word descriptor    */

/* ---------------- reduction ops (2-bit code, matches RTL) ----------------- */
#define ARC_OP_SUM   0     /* wrapping 32-bit add   (ncclSum)                 */
#define ARC_OP_PROD  1     /* wrapping 32-bit mul   (ncclProd)                */
#define ARC_OP_MAX   2     /* signed max            (ncclMax)                 */
#define ARC_OP_MIN   3     /* signed min            (ncclMin)                 */

/* ---------------- descriptor word layout ---------------------------------- *
 * w0  : ctrl  [1:0]=op   [8]=valid (1=process, 0=stop/skip -> error)
 * w1  : n     element count for this collective
 * w2  : dst_base   destination buffer base (word address)
 * w3.. : src_base[0..R-1]  per-rank source buffer base (word address)
 * rest : reserved (0)                                                        */
#define ARC_D_CTRL   0
#define ARC_D_N      1
#define ARC_D_DST    2
#define ARC_D_SRC0   3

#define ARC_CTRL_OP_MASK  0x3u
#define ARC_CTRL_VALID    (1u << 8)

/* ---------------- MMIO register map --------------------------------------- */
#define REG_CTRL       0x00  /* [0]=start(W1 pulse) [1]=soft_reset [2]=irq_en */
#define REG_STATUS     0x04  /* [0]=done_irq(W1C) [1]=err_irq(W1C) [2]=busy   */
#define REG_DESC_BASE  0x08  /* descriptor-ring base (word address)           */
#define REG_DESC_COUNT 0x0C  /* number of descriptors to process              */
#define REG_COMPLETED  0x10  /* descriptors completed (RO)                    */
#define REG_GROUPS     0x14  /* result groups streamed (RO)                   */
#define REG_WORDS      0x18  /* result words written (RO)                     */
#define REG_SCRATCH    0x1C  /* RW scratch (bus sanity)                       */
#define REG_PARAMS     0x20  /* [7:0]=R [15:8]=P [23:16]=DW (RO)              */
#define REG_VERSION    0x24  /* 0xFEED000E (day 14) (RO)                       */
#define REG_ERRCODE    0x28  /* last error code (RO)                          */

#define CTRL_START     (1u << 0)
#define CTRL_SRESET    (1u << 1)
#define CTRL_IRQEN     (1u << 2)
#define STATUS_DONE    (1u << 0)
#define STATUS_ERR     (1u << 1)
#define STATUS_BUSY    (1u << 2)

#define ARC_ERR_NONE   0
#define ARC_ERR_INVAL  1   /* descriptor not valid                           */
#define ARC_ERR_ZERON  2   /* n == 0                                         */

/* ---------------- shared reduction kernel (bit-exact vs RTL) -------------- *
 * reduce R rank values for one element into a single result.  Pure integer;
 * the RTL performs the identical wrapping / signed-compare operations.       */
static inline uint32_t arc_reduce(int op, const uint32_t *v, int r)
{
    int i;
    uint32_t acc = v[0];
    for (i = 1; i < r; i++) {
        switch (op) {
        case ARC_OP_SUM:  acc = (uint32_t)(acc + v[i]);            break;
        case ARC_OP_PROD: acc = (uint32_t)(acc * v[i]);            break;
        case ARC_OP_MAX:  acc = ((int32_t)v[i] > (int32_t)acc) ? v[i] : acc; break;
        case ARC_OP_MIN:  acc = ((int32_t)v[i] < (int32_t)acc) ? v[i] : acc; break;
        default:          break;
        }
    }
    return acc;
}

/* ---------------- reference + baseline entry points ----------------------- */
/* arc_ref.c : run one collective descriptor into the destination buffer.     */
void arc_run_desc(uint32_t *mem, uint32_t desc_base, int r, int p);

/* arc_baseline.c : documented scalar CPU cost model (cycles per element).    */
long arc_baseline_cycles_per_element(int r);

#endif /* ARC_H */
