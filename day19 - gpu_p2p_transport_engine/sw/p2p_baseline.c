/* ===========================================================================
 * p2p_baseline.c - cost model for doing the same transport in software.
 *
 * The comparison is against the honest software version of this job: a CPU
 * thread that reads the work queue, segments each message itself, builds every
 * packet header, copies each word out to the link and back in on the far side,
 * folds the accumulate opcode with ordinary loads and stores, checks flow
 * control before each packet and posts the completion entries. That is what a
 * host-driven or DPU-software datapath actually executes.
 *
 * Every term is a named per-operation cycle count so the number can be argued
 * with rather than taken on faith:
 *
 *   C_WQE_LOAD      4   one 32-bit descriptor word load
 *   C_WQE_CHECK    24   validating one descriptor (six branches)
 *   C_PKT_BUILD    12   composing the two header words of a packet
 *   C_PKT_POST     30   handing a packet to the link and updating sequence
 *   C_CREDIT        6   the flow-control test before a packet
 *   C_TX_WORD        8   load a payload word, push it to the link
 *   C_RX_WORD        8   pull a payload word off the link, store it
 *   C_ACC_WORD      13   pull, load destination, add, store back
 *   C_CQE_WORD       4   one completion-entry word store
 *   C_CQE_POST      20   completion bookkeeping per message
 *
 * These are deliberately unglamorous in-cache numbers - no cache misses, no
 * interrupt costs, no lock contention - so the speedup they produce is a floor
 * rather than a flattering figure.
 * ===========================================================================
 */
#include "p2p.h"

#define C_WQE_LOAD   4u
#define C_WQE_CHECK  24u
#define C_PKT_BUILD  12u
#define C_PKT_POST   30u
#define C_CREDIT     6u
#define C_TX_WORD    8u
#define C_RX_WORD    8u
#define C_ACC_WORD   13u
#define C_CQE_WORD   4u
#define C_CQE_POST   20u

void p2p_cost_reset(p2p_cost_t *c)
{
    c->wqe_loads = 0; c->pkt_builds = 0; c->tx_words = 0;
    c->rx_words = 0; c->accum_words = 0; c->cqe_posts = 0;
    c->credit_checks = 0; c->cycles = 0;
}

uint64_t p2p_cost_total(const p2p_cost_t *c)
{
    return c->cycles;
}

void p2p_cost_run(const uint32_t *mem, const p2p_run_t *r, p2p_cost_t *c)
{
    uint32_t i;

    for (i = 0; i < r->wq_count; i++) {
        uint32_t w0  = mem[(r->wq_base >> 2) + i * 8 + 0];
        uint32_t src = mem[(r->wq_base >> 2) + i * 8 + 1];
        uint32_t dst = mem[(r->wq_base >> 2) + i * 8 + 2];
        uint32_t len = mem[(r->wq_base >> 2) + i * 8 + 3];
        uint32_t op  = w0 & 0xFu;
        uint32_t qp  = (w0 >> 4) & 0xFu;
        uint32_t rem, err = 0;
        uint64_t src_end = (uint64_t)src + (uint64_t)len * 4u;
        uint64_t dst_end = (uint64_t)dst + (uint64_t)len * 4u;

        c->wqe_loads += P2P_WQE_WORDS;
        c->cycles    += (uint64_t)P2P_WQE_WORDS * C_WQE_LOAD + C_WQE_CHECK;

        if (op != P2P_OP_WRITE && op != P2P_OP_ACCUM) err = 1;
        else if (qp >= P2P_NUM_QP)                     err = 1;
        else if (len > (uint32_t)P2P_MAX_MSG_WORDS)    err = 1;
        else if ((src & 3u) || (dst & 3u))             err = 1;
        else if (src_end > r->mem_limit || dst_end > r->mem_limit) err = 1;
        if (err) continue;

        rem = len;
        do {
            uint32_t plen = (rem > (uint32_t)P2P_MTU_WORDS)
                                ? (uint32_t)P2P_MTU_WORDS : rem;
            uint32_t last = (rem <= (uint32_t)P2P_MTU_WORDS);

            c->pkt_builds++;
            c->credit_checks++;
            c->cycles += C_PKT_BUILD + C_PKT_POST + C_CREDIT;

            c->tx_words += plen;
            c->cycles   += (uint64_t)plen * C_TX_WORD;

            if (op == P2P_OP_ACCUM) {
                c->accum_words += plen;
                c->cycles      += (uint64_t)plen * C_ACC_WORD;
            } else {
                c->rx_words += plen;
                c->cycles   += (uint64_t)plen * C_RX_WORD;
            }

            if (last) {
                c->cqe_posts++;
                c->cycles += (uint64_t)P2P_CQE_WORDS * C_CQE_WORD + C_CQE_POST;
            }
            rem -= plen;
        } while (rem > 0);
    }
}
