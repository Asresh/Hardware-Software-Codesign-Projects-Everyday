/* ============================================================================
 * kvp.h - shared contract for the KV-cache paging engine.
 *
 *   Register map, request/result encodings, translation-cache geometry and the
 *   golden-model API.  rtl/kvp_defs.vh carries the identical encodings on the
 *   hardware side; tb/kvp_tb.sv re-declares them and the testbench checks the
 *   VERSION register, so a drift between the three shows up as a failing test
 *   rather than as a silent disagreement.
 * ==========================================================================*/
#ifndef KVP_H
#define KVP_H

#include <stdint.h>
#include <stdio.h>

/* ---------------- translation-cache geometry ---------------- */
#ifndef KVP_SETS
#define KVP_SETS 16
#endif
#ifndef KVP_WAYS
#define KVP_WAYS 4
#endif
#ifndef KVP_FREE_DEPTH
#define KVP_FREE_DEPTH 512
#endif

#define KVP_SEQ_W  12
#define KVP_LOG_W  16
#define KVP_KEY_W  (KVP_SEQ_W + KVP_LOG_W)
#define KVP_PHYS_W 24
#define KVP_PHYS_MASK ((1u << KVP_PHYS_W) - 1u)

#define KVP_SET_BITS (KVP_SETS ==  2 ? 1 : KVP_SETS ==  4 ? 2 : \
                      KVP_SETS ==  8 ? 3 : KVP_SETS == 16 ? 4 : \
                      KVP_SETS == 32 ? 5 : KVP_SETS == 64 ? 6 : 7)

/* ---------------- system memory layout (word indices) ---------------- */
#define KVP_MEM_WORDS   16384
#define KVP_BT_BASE_W   0        /* block table: NUM_SEQ rows of BT_STRIDE words */
#define KVP_BT_STRIDE   64
#define KVP_NUM_SEQ     32
#define KVP_REQ_BASE_W  2048     /* request arrays                              */
#define KVP_RES_BASE_W  4096     /* result arrays                               */
#define KVP_MAX_RES     (KVP_MEM_WORDS - KVP_RES_BASE_W)
#define KVP_BT_WORDS    (KVP_NUM_SEQ * KVP_BT_STRIDE)

#define KVP_BT_INVALID  0xFFFFFFFFu

/* ---------------- MMIO register indices (byte address = index*4) ------- */
enum {
    R_CTRL = 0, R_STATUS, R_REQ_BASE, R_RES_BASE, R_REQ_COUNT,
    R_BT_BASE, R_BT_STRIDE, R_FREE_PUSH, R_FREE_COUNT,
    R_STAT_REQS, R_STAT_XLATES, R_STAT_HITS, R_STAT_MISSES,
    R_STAT_ALLOCS, R_STAT_FREES, R_STAT_ERRS, R_LAST_CYC,
    R_RES_WORDS, R_IRQ_ACK, R_VERSION
};

#define CTRL_START  (1u << 0)
#define CTRL_SRST   (1u << 1)
#define CTRL_IRQEN  (1u << 2)

#define ST_BUSY     (1u << 0)
#define ST_DONE     (1u << 1)
#define ST_OOM      (1u << 2)
#define ST_BUS      (1u << 3)
#define ST_IRQ      (1u << 4)

#define KVP_VERSION_ID 0x00160001u

/* ---------------- request word: {op[3:0], seq[11:0], arg[15:0]} -------- */
#define OP_XLATE   0u   /* arg = logical block; allocate if unmapped          */
#define OP_RANGE   1u   /* arg = count; translate logical 0..count-1          */
#define OP_NOALLOC 2u   /* arg = logical block; error if unmapped             */
#define OP_FREE    3u   /* arg = count; return blocks 0..count-1 to the pool  */
#define OP_FLUSH   4u   /* invalidate the whole translation cache             */

static inline uint32_t kvp_req(uint32_t op, uint32_t seq, uint32_t arg)
{
    return (op << 28) | ((seq & 0xFFFu) << 16) | (arg & 0xFFFFu);
}

/* ---------------- result word: {flags[7:0], payload[23:0]} ------------- */
#define F_HIT     (1u << 0)
#define F_ALLOC   (1u << 1)
#define F_FREED   (1u << 2)   /* payload = number of blocks returned */
#define F_FLUSHED (1u << 3)
#define F_EINVAL  (1u << 4)
#define F_EOOM    (1u << 5)
#define F_EBADOP  (1u << 6)

static inline uint32_t kvp_res(uint32_t flags, uint32_t payload)
{
    return (flags << 24) | (payload & KVP_PHYS_MASK);
}

/* ---------------- golden model ---------------- */
typedef struct {
    uint8_t  valid[KVP_SETS * KVP_WAYS];
    uint32_t tag  [KVP_SETS * KVP_WAYS];
    uint32_t phys [KVP_SETS * KVP_WAYS];
    uint8_t  order[KVP_SETS][KVP_WAYS];      /* order[s][0] = MRU */

    uint32_t stack[KVP_FREE_DEPTH];
    int      sp;

    /* cumulative statistics, cleared by kvp_soft_reset() */
    uint32_t reqs, xlates, hits, misses, allocs, frees, errs;
    int      sticky_oom;
} kvp_state_t;

void     kvp_soft_reset(kvp_state_t *st);
void     kvp_push_free(kvp_state_t *st, uint32_t blk);
/* Run `nreq` request words at mem[req_base_w..], writing results at
 * mem[res_base_w..].  Returns the number of result words produced. */
uint32_t kvp_run_batch(kvp_state_t *st, uint32_t *mem,
                       uint32_t req_base_w, uint32_t res_base_w, uint32_t nreq);

/* scalar software-only cost model (sw/kvp_baseline.c) */
uint64_t kvp_baseline_cycles(uint64_t reqs, uint64_t hits, uint64_t misses,
                             uint64_t allocs, uint64_t frees);
void     kvp_baseline_terms(FILE *f);

#endif /* KVP_H */
