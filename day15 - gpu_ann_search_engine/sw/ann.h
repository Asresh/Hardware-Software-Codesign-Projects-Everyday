/* ============================================================================
 * ann.h - shared definitions for the GPU vector-search (ANN) top-K engine.
 *
 * One header shared by the reference model, the scalar baseline, the firmware
 * driver, and the stimulus/golden host.  The register map here is the exact
 * contract the RTL (ann_regfile.v) implements and the testbench drives.
 * ==========================================================================*/
#ifndef ANN_H
#define ANN_H

#include <stdint.h>

/* ---- design parameters (overridable at compile time to match RTL) -------- */
#ifndef ANN_D
#define ANN_D 64          /* vector dimensionality (int8 elements)            */
#endif
#ifndef ANN_P
#define ANN_P 8           /* SIMD lanes = int8 elements consumed per beat     */
#endif
#ifndef ANN_K
#define ANN_K 8           /* top-K results kept                               */
#endif

#define ANN_CHUNKS (ANN_D / ANN_P)     /* AXI-Stream beats per database vector */

/* ---- similarity metrics -------------------------------------------------- */
enum { ANN_METRIC_L2 = 0,     /* squared-L2 distance, keep K smallest         */
       ANN_METRIC_IP = 1 };   /* inner product (dot),  keep K largest         */

/* ---- MMIO register map (32-bit words; index = byte address >> 2) --------- */
#define REG_CTRL      0   /* [0]=START [1]=SRESET [2]=IRQEN [8]=METRIC         */
#define REG_STATUS    1   /* [0]=DONE [1]=ERR [2]=BUSY [3]=IRQ                 */
#define REG_NDB       2   /* database vectors expected in this shard           */
#define REG_IRQ_ACK   3   /* W1C: clears DONE/ERR/IRQ                          */
#define REG_VERSION   4   /* read-only build id                               */
#define REG_STAT_VECS 5   /* cumulative vectors scored                        */
#define REG_STAT_BEATS 6  /* cumulative stream beats consumed                 */
#define REG_LAST_CYC  7   /* cycle span of the last search (first beat->done) */
#define REG_ERRCODE   8   /* last error code                                  */

/* Windows are spaced so the map stays disjoint up to D=256 / K=32:
 *   query  : 32 .. 32+D/4-1   (<= 95)
 *   scores : 128 .. 128+K-1   (<= 159)
 *   ids    : 192 .. 192+K-1   (<= 223)                                        */
#define REG_QUERY_BASE  32               /* query window: ANN_D/4 words        */
#define REG_QUERY_WORDS (ANN_D / 4)
#define REG_SCORE_BASE  128              /* top-K scores  : ANN_K words        */
#define REG_ID_BASE     192              /* top-K ids     : ANN_K words        */

#define CTRL_START   (1u << 0)
#define CTRL_SRESET  (1u << 1)
#define CTRL_IRQEN   (1u << 2)
#define CTRL_METRIC  (1u << 8)

#define ST_DONE  (1u << 0)
#define ST_ERR   (1u << 1)
#define ST_BUSY  (1u << 2)
#define ST_IRQ   (1u << 3)

#define ANN_VERSION 0x00150001u
#define ERR_TRUNC   1u        /* TLAST inside a vector (malformed shard)       */

/* sentinels for empty result slots (signed 32-bit score domain) */
#define SCORE_SENT_L2  0x7FFFFFFF     /* +max: worse than any real distance    */
#define SCORE_SENT_IP  ((int32_t)0x80000000)  /* -min: worse than any real dot */
#define ID_SENT        (-1)

/* one result entry */
typedef struct { int32_t score; int32_t id; } ann_entry_t;

/* reference model: compute the top-K of one search.
 *   metric : ANN_METRIC_L2 | ANN_METRIC_IP
 *   q      : ANN_D int8 query elements
 *   db     : n * ANN_D int8 database elements (row-major, vector-major)
 *   out    : ANN_K entries, filled best->worst; unused slots get sentinels
 * returns the number of valid entries (min(n, ANN_K)).                       */
int ann_topk_ref(int metric, const int8_t *q, const int8_t *db, int n,
                 ann_entry_t *out);

/* scalar software-only baseline: returns the modelled cycle cost of scoring
 * one search on a single scalar lane (documented cost model).               */
uint64_t ann_baseline_cycles(int metric, int n);

#endif /* ANN_H */
