/* emb.h - shared definitions for the sharded embedding gather-reduce engine.
 *
 * One header for the golden model, the scalar baseline, the firmware driver and
 * the vector generator, so that the C side and the RTL side are built from the
 * same numbers.  Compile-time overrides (-DEMB_DIM=... etc.) come from the
 * Makefile and are also emitted into tb/vectors/emb_const.vh for the RTL.
 */
#ifndef EMB_H
#define EMB_H

#include <stdint.h>
#include <stddef.h>

/* ------------------------------------------------------------------ geometry */
#ifndef EMB_DIM
#define EMB_DIM 64 /* embedding vector length, in 32-bit words           */
#endif
#ifndef EMB_LANES
#define EMB_LANES 4 /* SIMD lanes == memory beat width, in words          */
#endif
#ifndef EMB_MAX_BAG
#define EMB_MAX_BAG 64 /* deepest bag the index buffer can hold              */
#endif
#ifndef EMB_LOCAL_ROWS
#define EMB_LOCAL_ROWS 256 /* rows of the global table held on this device       */
#endif
#ifndef EMB_TABLE_ROWS
#define EMB_TABLE_ROWS 4096 /* rows of the *global* (sharded) table               */
#endif
#ifndef EMB_SHARD_LO
#define EMB_SHARD_LO 1024 /* first global row owned by this device              */
#endif

#define EMB_CHUNKS (EMB_DIM / EMB_LANES) /* memory beats per embedding row */
#define EMB_SHARD_HI (EMB_SHARD_LO + EMB_LOCAL_ROWS)

/* --------------------------------------------------------------- descriptors */
/* 8 words / 32 bytes each, so a descriptor is beat-aligned for LANES in {2,4,8} */
#define EMB_DESC_WORDS 8

#define EMB_OP_SUM 0
#define EMB_OP_MEAN 1
#define EMB_OP_MAX 2
#define EMB_OP_MIN 3

/* ------------------------------------------------------------ shared-memory map
 * Word offsets into the device-visible memory image.  Everything is aligned to
 * a LANES-word memory beat.  Sizes are fixed by the generator.
 */
#define EMB_DESC_BASE 64                                                /* descriptor ring   */
#define EMB_MAX_DESC 352                                                /* ring capacity     */
#define EMB_IDX_BASE (EMB_DESC_BASE + EMB_MAX_DESC * EMB_DESC_WORDS)     /* index arena       */
#define EMB_IDX_WORDS (EMB_MAX_DESC * EMB_MAX_BAG)                      /* arena capacity    */
#define EMB_TAB_BASE (EMB_IDX_BASE + EMB_IDX_WORDS)                      /* local table shard */
#define EMB_TAB_WORDS (EMB_LOCAL_ROWS * EMB_DIM)
#define EMB_OUT_BASE (EMB_TAB_BASE + EMB_TAB_WORDS)                      /* pooled outputs    */
#define EMB_OUT_WORDS (EMB_MAX_DESC * EMB_DIM)

/* total device memory the model and the testbench allocate; derived so that the
 * image still fits when the geometry is swept */
#define EMB_MEM_WORDS (EMB_OUT_BASE + EMB_OUT_WORDS + 64)

/* Poison written into the output region before a run: any word the engine does
 * not write must still hold this afterwards, so a missing write is a mismatch. */
#define EMB_POISON 0xDEADC0DEu

/* ------------------------------------------------------------ MMIO register map */
#define EMB_REG_CTRL 0x00
#define EMB_REG_STATUS 0x04
#define EMB_REG_IRQ 0x08
#define EMB_REG_DESC_BASE 0x0C
#define EMB_REG_DESC_COUNT 0x10
#define EMB_REG_IDX_BASE 0x14
#define EMB_REG_TAB_BASE 0x18
#define EMB_REG_OUT_BASE 0x1C
#define EMB_REG_SHARD_LO 0x20
#define EMB_REG_SHARD_HI 0x24
#define EMB_REG_TABLE_ROWS 0x28
#define EMB_REG_ST_DESC 0x2C
#define EMB_REG_ST_IDX 0x30
#define EMB_REG_ST_LOCAL 0x34
#define EMB_REG_ST_REMOTE 0x38
#define EMB_REG_ST_INVALID 0x3C
#define EMB_REG_ST_RBEATS 0x40
#define EMB_REG_ST_WBEATS 0x44
#define EMB_REG_ST_CYCLES 0x48
#define EMB_REG_ID 0x4C

/* CTRL */
#define EMB_CTRL_START (1u << 0)
#define EMB_CTRL_SINGLE_BUF (1u << 1) /* disable ping-pong overlap (A/B study) */
#define EMB_CTRL_IRQ_EN (1u << 2)
#define EMB_CTRL_CLR_STATS (1u << 3)

/* STATUS */
#define EMB_ST_BUSY (1u << 0)
#define EMB_ST_DONE (1u << 1)
#define EMB_ST_ERR_BAGLEN (1u << 2)
#define EMB_ST_ERR_INDEX (1u << 3)
#define EMB_ST_ERR_BUS (1u << 4)

/* IRQ (write-1-to-clear) */
#define EMB_IRQ_DONE (1u << 0)
#define EMB_IRQ_ERROR (1u << 1)

#define EMB_ID_MAGIC 0xE9B00000u /* ID = MAGIC | LANES<<8 | log2-ish dim tag */

/* --------------------------------------------------------------- descriptor */
typedef struct {
    uint32_t op;      /* EMB_OP_*                                    */
    uint32_t num_idx; /* bag length                                  */
    uint32_t idx_off; /* word offset of the bag inside the arena      */
    uint32_t dst_off; /* word offset of the EMB_DIM-word pooled output*/
} emb_desc_t;

/* ------------------------------------------------------------- golden model */
typedef struct {
    uint32_t desc;        /* descriptors retired                        */
    uint32_t idx;         /* indices examined                           */
    uint32_t local;       /* indices that hit this shard (rows gathered) */
    uint32_t remote;      /* indices owned by a peer shard              */
    uint32_t invalid;     /* indices >= table_rows                      */
    uint32_t err_baglen;  /* descriptors rejected for num_idx > MAX_BAG  */
    uint32_t rbeats;      /* memory read beats the engine must issue    */
    uint32_t wbeats;      /* memory write beats the engine must issue   */
} emb_stats_t;

typedef struct {
    uint32_t shard_lo, shard_hi, table_rows;
} emb_cfg_t;

void emb_model_run(const uint32_t *mem, uint32_t *out_mem, const emb_cfg_t *cfg,
                   uint32_t desc_base, uint32_t desc_count, uint32_t idx_base,
                   uint32_t tab_base, uint32_t out_base, emb_stats_t *st);

/* scalar software-only baseline cost model (documented in emb_baseline.c) */
uint64_t emb_baseline_cycles(const uint32_t *mem, const emb_cfg_t *cfg,
                             uint32_t desc_base, uint32_t desc_count,
                             uint32_t idx_base, uint64_t *ops_out);

#endif /* EMB_H */
