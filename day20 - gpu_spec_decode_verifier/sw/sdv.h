/* ============================================================================
 * sdv.h - register map, wire formats and shared types for the speculative
 *         decoding draft-tree verifier.
 *
 * One header shared by the firmware driver, the golden model, the scalar
 * baseline and the stimulus generator.  rtl/sdv_defs.vh is the Verilog mirror
 * of this file; REG_REGMAP_CSUM is read back in simulation and compared with
 * SDV_REGMAP_CSUM below, so the two cannot drift apart silently.
 * ==========================================================================*/
#ifndef SDV_H
#define SDV_H

#include <stdint.h>

/* ---- build-time geometry (RTL, model and testbench share these) ---------- */
#ifndef SDV_MAX_NODES
#define SDV_MAX_NODES 64        /* draft-tree nodes held on chip            */
#endif
#ifndef SDV_MAX_DEPTH
#define SDV_MAX_DEPTH 16        /* longest acceptable path (tokens/job)     */
#endif

#define SDV_ROOT_PARENT 0xFFFFu /* parent field of node 0                   */

/* ---- node record: one 128-bit ingress beat ------------------------------
 *   w0 [15:0]  parent node index (0xFFFF on the root)
 *   w1         draft token id proposed at this node
 *   w2         target model's argmax token at this node's position ("pred")
 *   w3 [15:0]  score : target prob of THIS node's draft token, taken from the
 *                      parent's distribution, unsigned Q0.16
 *      [31:16] pmax  : the largest target prob at THIS node's position, Q0.16
 *                      (used when this node acts as a parent)
 * ------------------------------------------------------------------------*/
typedef struct {
    uint32_t parent;
    uint32_t tok;
    uint32_t pred;
    uint16_t score;
    uint16_t pmax;
} sdv_node_t;

/* ---- acceptance modes (CTRL[3:2]) --------------------------------------- */
#define SDV_MODE_GREEDY  0u     /* tok == pred(parent)                       */
#define SDV_MODE_TYPICAL 1u     /* score >= max(TH_ABS, pmax(parent)*TH_REL) */
#define SDV_MODE_BOTH    2u     /* greedy AND typical                        */
#define SDV_MODE_ANY     3u     /* greedy OR typical                         */

/* ---- error codes (REG_ERRCODE, trailer word 2), in detection priority --- */
#define SDV_ERR_NONE    0u
#define SDV_ERR_NNODES  1u      /* more beats in a job than MAX_NODES        */
#define SDV_ERR_ROOT    2u      /* node 0 not a root, or a second root       */
#define SDV_ERR_PARENT  3u      /* parent index >= node count                */
#define SDV_ERR_SELF    4u      /* node is its own parent                    */

/* ---- trailer flags (trailer word 3, low half) --------------------------- */
#define SDV_FLAG_CLAMP  0x1u    /* a candidate existed but the cap was hit   */

/* ---- register map (byte offsets on the APB3 control plane) -------------- */
#define SDV_REG_CTRL        0x00u
#define SDV_REG_STATUS      0x04u
#define SDV_REG_TH_ABS      0x08u
#define SDV_REG_TH_REL      0x0Cu
#define SDV_REG_MAX_ACC     0x10u
#define SDV_REG_IRQ_STAT    0x14u   /* write-1-to-clear                      */
#define SDV_REG_ERRCODE     0x18u
#define SDV_REG_CAPS        0x1Cu
#define SDV_REG_VERSION     0x20u
#define SDV_REG_ST_JOBS     0x24u
#define SDV_REG_ST_NODES    0x28u
#define SDV_REG_ST_ACCEPT   0x2Cu
#define SDV_REG_ST_ERRJOBS  0x30u
#define SDV_REG_ST_CLAMP    0x34u
#define SDV_REG_ST_BUSY     0x38u   /* cycles not idle                       */
#define SDV_REG_ST_SRCSTALL 0x3Cu   /* loading, but tvalid low               */
#define SDV_REG_ST_BPSTALL  0x40u   /* tvalid high, engine not ready         */
#define SDV_REG_ST_LASTCYC  0x44u   /* first beat -> trailer, last job       */
#define SDV_REG_ST_LASTACC  0x48u
#define SDV_REG_REGMAP_CSUM 0x4Cu
#define SDV_REG_HIST_BASE   0x80u   /* MAX_DEPTH counters, one per position  */

#define SDV_CTRL_EN       0x001u
#define SDV_CTRL_IRQ_EN   0x002u
#define SDV_CTRL_MODE_SH  2
#define SDV_CTRL_MODE_MSK 0x00Cu
#define SDV_CTRL_CLR_STAT 0x100u    /* self-clearing                         */
#define SDV_CTRL_SOFT_RST 0x200u    /* self-clearing                         */

#define SDV_IRQ_DONE      0x1u
#define SDV_IRQ_ERROR     0x2u
#define SDV_IRQ_CLAMP     0x4u

#define SDV_STATUS_BUSY   0x1u
#define SDV_STATUS_EGEMPT 0x2u

#define SDV_VERSION       0x00200001u
/* checksum over the register map: sum of (offset * (index+1)), mirrored in
 * rtl/sdv_defs.vh.  Any edit to one side without the other fails in sim. */
#define SDV_REGMAP_CSUM   0x00003410u

/* ---- egress beat formats -------------------------------------------------
 * accepted-token beat: w0 = node index, w1 = token, w2 = score, w3 = depth
 * trailer beat (TLAST): w0 = accepted count, w1 = bonus token,
 *                       w2 = error code, w3 = (nodes<<16) | flags
 * ------------------------------------------------------------------------*/
typedef struct {
    uint32_t w[4];
} sdv_beat_t;

/* one verification job as the host builds it */
typedef struct {
    uint32_t   mode;
    uint32_t   th_abs;
    uint32_t   th_rel;
    uint32_t   max_acc;
    uint32_t   n_nodes;                 /* beats streamed in                 */
    sdv_node_t node[SDV_MAX_NODES + 8]; /* +8 so over-length jobs fit        */
} sdv_job_t;

/* aggregate counters the hardware keeps, reproduced by the model */
typedef struct {
    uint32_t jobs, nodes, accept, errjobs, clamp;
    uint32_t hist[SDV_MAX_DEPTH];
} sdv_stats_t;

/* golden model (sdv_model.c): returns the number of egress beats written */
int sdv_verify(const sdv_job_t *job, sdv_beat_t *out, int out_max,
               sdv_stats_t *st);

/* scalar baseline (sdv_baseline.c): same result, plus a cycle cost model */
typedef struct {
    uint64_t words_loaded;   /* 32-bit words pulled from memory             */
    uint64_t node_visits;    /* nodes examined across all path steps        */
    uint64_t compares;       /* acceptance predicate evaluations            */
    uint64_t muls;           /* relative-threshold multiplies               */
    uint64_t stores;         /* result words written                        */
    uint64_t cycles;         /* the cost model's total                      */
} sdv_cost_t;

int sdv_baseline(const sdv_job_t *job, sdv_beat_t *out, int out_max,
                 sdv_cost_t *cost);

#endif /* SDV_H */
