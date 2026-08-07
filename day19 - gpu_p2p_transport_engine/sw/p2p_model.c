/* ===========================================================================
 * p2p_model.c - golden model of one transport launch.
 *
 * This is a message-level mirror of the RTL, not a cycle-level one, and it can
 * be because the design is built so that the result does not depend on timing:
 * the work queue is drained in order, packets leave in order, and the receiver
 * retires them in order, so the only thing that can change what memory ends up
 * holding is the descriptor ring itself.  The testbench relies on exactly that
 * - it runs the same launches under randomised bus and link delay and again at
 * full rate and demands byte-identical memory both times.
 *
 * The details that actually have to match, and that a looser model would get
 * wrong:
 *   - the fixed error priority in descriptor validation;
 *   - sequence numbers are per queue pair and wrap at 8 bits;
 *   - a packet dropped on a sequence gap writes nothing, posts nothing, and
 *     does not clear the running byte count of the message it belonged to;
 *   - the byte count in a completion entry counts only the packets that were
 *     actually committed;
 *   - ACCUM is a 32-bit wrapping two's-complement add against whatever the
 *     destination held at that moment, so overlapping destinations compose in
 *     retirement order.
 * ===========================================================================
 */
#include "p2p.h"
#include <string.h>

static uint32_t rd(const uint32_t *mem, uint32_t byte_addr)
{
    return mem[byte_addr >> 2];
}

void p2p_model_run(uint32_t *mem, uint32_t mem_words, p2p_run_t *r)
{
    uint8_t  seq[P2P_NUM_QP], exp[P2P_NUM_QP];
    uint32_t msg_bytes[P2P_NUM_QP];
    uint32_t cqe_idx = 0;
    int      inj_armed = (r->inject != 0);
    uint32_t i, q;

    (void)mem_words;

    for (q = 0; q < P2P_NUM_QP; q++) {
        seq[q] = 0; exp[q] = 0; msg_bytes[q] = 0;
    }

    r->st_wqe = r->st_pkt = r->st_txw = r->st_rxw = 0;
    r->st_cqe = r->st_err = r->st_seq = 0;
    r->err_code = P2P_ERR_NONE;
    r->err_index = 0;

    for (i = 0; i < r->wq_count; i++) {
        uint32_t w0 = rd(mem, r->wq_base + i * 32 + 0);
        uint32_t src = rd(mem, r->wq_base + i * 32 + 4);
        uint32_t dst = rd(mem, r->wq_base + i * 32 + 8);
        uint32_t len = rd(mem, r->wq_base + i * 32 + 12);
        uint32_t tag = rd(mem, r->wq_base + i * 32 + 16) & 0xFFu;
        uint32_t op  = w0 & 0xFu;
        uint32_t qp  = (w0 >> 4) & 0xFu;
        uint32_t err = P2P_ERR_NONE;
        uint32_t rem, first;
        uint64_t src_end = (uint64_t)src + (uint64_t)len * 4u;
        uint64_t dst_end = (uint64_t)dst + (uint64_t)len * 4u;

        /* fixed validation priority - the same order as the RTL */
        if (op != P2P_OP_WRITE && op != P2P_OP_ACCUM)      err = P2P_ERR_OP;
        else if (qp >= P2P_NUM_QP)                          err = P2P_ERR_QP;
        else if (len > (uint32_t)P2P_MAX_MSG_WORDS)         err = P2P_ERR_LEN;
        else if ((src & 3u) || (dst & 3u))                  err = P2P_ERR_ALIGN;
        else if (src_end > r->mem_limit || dst_end > r->mem_limit)
                                                            err = P2P_ERR_RANGE;

        if (err != P2P_ERR_NONE) {
            r->st_err++;
            if (r->err_code == P2P_ERR_NONE) {
                r->err_code  = err;
                r->err_index = i;
            }
            continue;
        }

        r->st_wqe++;
        rem = len;
        first = 1;

        do {
            uint32_t plen  = (rem > (uint32_t)P2P_MTU_WORDS)
                                 ? (uint32_t)P2P_MTU_WORDS : rem;
            uint32_t last  = (rem <= (uint32_t)P2P_MTU_WORDS);
            uint8_t  s     = seq[qp];
            int      drop;
            uint32_t k;

            r->st_pkt++;
            r->st_txw += plen;

            if (inj_armed) { seq[qp] = (uint8_t)(s + 2); inj_armed = 0; }
            else           { seq[qp] = (uint8_t)(s + 1); }

            drop = (s != exp[qp]);
            exp[qp] = (uint8_t)(s + 1);

            if (drop) {
                r->st_seq++;
            } else {
                for (k = 0; k < plen; k++) {
                    uint32_t v = mem[(src >> 2) + k];
                    if (op == P2P_OP_ACCUM) mem[(dst >> 2) + k] += v;
                    else                    mem[(dst >> 2) + k]  = v;
                }
                r->st_rxw += plen;
                msg_bytes[qp] += plen * 4u;

                if (last) {
                    uint32_t base = (r->cq_base >> 2) + cqe_idx * 4u;
                    mem[base + 0] = ((op == P2P_OP_ACCUM ? 1u : 0u) << 12) |
                                    (qp << 8) | 0u;
                    mem[base + 1] = tag;
                    mem[base + 2] = msg_bytes[qp];
                    mem[base + 3] = s;
                    cqe_idx++;
                    r->st_cqe++;
                    msg_bytes[qp] = 0;
                }
            }

            src += plen * 4u;
            dst += plen * 4u;
            rem -= plen;
            first = 0;
            (void)first;
        } while (rem > 0);
    }

    r->status_err = (r->err_code != P2P_ERR_NONE) || (r->st_seq != 0);
}
