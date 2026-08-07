/* ===========================================================================
 * p2p.h - register map, descriptor formats and shared declarations for the
 * GPU-to-GPU peer transport engine.
 *
 * Every constant here has a twin in rtl/p2p_defs.vh. The two are kept honest
 * rather than merely intended to match: p2p_host.c emits a checksum of this
 * register map into the testbench parameters, and the testbench compares it
 * against the same sum computed from the RTL header, so a register that moves
 * on one side and not the other fails the run.
 * ===========================================================================
 */
#ifndef P2P_H
#define P2P_H

#include <stdint.h>
#include <stddef.h>

/* ---- geometry (overridable from the Makefile) --------------------------- */
#ifndef P2P_MTU_WORDS
#define P2P_MTU_WORDS 16
#endif
#ifndef P2P_NUM_QP
#define P2P_NUM_QP 4
#endif
#ifndef P2P_RX_BUFS
#define P2P_RX_BUFS 4
#endif
#ifndef P2P_MAX_MSG_WORDS
#define P2P_MAX_MSG_WORDS 4096
#endif

/* ---- control-plane registers (byte offsets) ----------------------------- */
#define P2P_CTRL        0x00u
#define P2P_STATUS      0x04u
#define P2P_WQ_BASE     0x08u
#define P2P_WQ_COUNT    0x0Cu
#define P2P_CQ_BASE     0x10u
#define P2P_MEM_LIMIT   0x14u
#define P2P_CREDIT_LIM  0x18u
#define P2P_INJECT      0x1Cu
#define P2P_IRQ_EN      0x20u
#define P2P_IRQ_STAT    0x24u
#define P2P_ERR_CODE    0x28u
#define P2P_ERR_INFO    0x2Cu
#define P2P_ST_WQE      0x30u
#define P2P_ST_PKT      0x34u
#define P2P_ST_TXW      0x38u
#define P2P_ST_RXW      0x3Cu
#define P2P_ST_CQE      0x40u
#define P2P_ST_ERR      0x44u
#define P2P_ST_SEQ      0x48u
#define P2P_ST_CYCLES   0x4Cu
#define P2P_ST_CRSTALL  0x50u
#define P2P_ST_LKSTALL  0x54u
#define P2P_ST_MEMSTALL 0x58u
#define P2P_CAPS        0x5Cu

#define P2P_CTRL_START      (1u << 0)
#define P2P_CTRL_SOFTRESET  (1u << 1)
#define P2P_STATUS_BUSY     (1u << 0)
#define P2P_STATUS_DONE     (1u << 1)
#define P2P_STATUS_ERR      (1u << 2)
#define P2P_STATUS_SEQERR   (1u << 3)
#define P2P_IRQ_DONE        (1u << 0)
#define P2P_IRQ_ERR         (1u << 1)

/* ---- opcodes ------------------------------------------------------------ */
#define P2P_OP_WRITE 0u
#define P2P_OP_ACCUM 1u

/* ---- error codes -------------------------------------------------------- */
#define P2P_ERR_NONE  0u
#define P2P_ERR_OP    1u
#define P2P_ERR_QP    2u
#define P2P_ERR_LEN   3u
#define P2P_ERR_ALIGN 4u
#define P2P_ERR_RANGE 5u
#define P2P_ERR_BUS   6u

/* ---- link header flags -------------------------------------------------- */
#define P2P_FLAG_FIRST 0x1u
#define P2P_FLAG_LAST  0x2u
#define P2P_FLAG_ACCUM 0x4u

#define P2P_WQE_WORDS 8
#define P2P_CQE_WORDS 4

/* ---- host-side descriptor ----------------------------------------------- */
typedef struct {
    uint32_t opcode;
    uint32_t qp;
    uint32_t src;        /* byte address */
    uint32_t dst;        /* byte address */
    uint32_t len;        /* words */
    uint32_t tag;        /* echoed into the completion entry */
} p2p_wqe_t;

/* ---- one launch: the ring, and everything the engine must report --------- */
typedef struct {
    uint32_t wq_base, wq_count, cq_base, mem_limit;
    uint32_t credit_lim, inject;

    /* golden values, all timing independent */
    uint32_t st_wqe, st_pkt, st_txw, st_rxw, st_cqe, st_err, st_seq;
    uint32_t err_code, err_index, status_err;
} p2p_run_t;

/* golden model: applies one launch to `mem` (word addressed) and fills in the
 * expected counter values.  Bit-exact mirror of the RTL. */
void p2p_model_run(uint32_t *mem, uint32_t mem_words, p2p_run_t *r);

/* documented scalar cost model for a software-only transport */
typedef struct {
    uint64_t wqe_loads, pkt_builds, tx_words, rx_words, accum_words;
    uint64_t cqe_posts, credit_checks;
    uint64_t cycles;
} p2p_cost_t;

void p2p_cost_reset(p2p_cost_t *c);
void p2p_cost_run(const uint32_t *mem, const p2p_run_t *r, p2p_cost_t *c);
uint64_t p2p_cost_total(const p2p_cost_t *c);

/* firmware entry points (built, not run, by the host program) */
void p2p_driver_launch(volatile uint32_t *csr, const p2p_run_t *r);
int  p2p_driver_wait(volatile uint32_t *csr);

#endif /* P2P_H */
