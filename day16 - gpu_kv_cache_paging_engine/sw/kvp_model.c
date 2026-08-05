/* ============================================================================
 * kvp_model.c - golden model of the KV-cache paging engine.
 *
 *   A cycle-independent but bit-exact reference: same key/index/tag split, same
 *   true-LRU move-to-front replacement with invalid-way-first victim choice,
 *   same LIFO physical-block pool, same block-table poison value, same result
 *   encodings and the same statistics accounting as rtl/kvp_core.v.
 *
 *   Because replacement and allocation are both deterministic functions of the
 *   request stream, every physical block number, every hit/miss decision and
 *   every counter is predictable - which is what makes the differential test
 *   meaningful rather than a smoke test.
 * ==========================================================================*/
#include "kvp.h"

/* ---------------- translation cache ---------------- */

static void tlb_reset(kvp_state_t *st)
{
    int s, w;
    for (s = 0; s < KVP_SETS; s++) {
        for (w = 0; w < KVP_WAYS; w++) {
            st->valid[s * KVP_WAYS + w] = 0;
            st->order[s][w] = (uint8_t)w;         /* identity: way 0 is MRU */
        }
    }
}

static void mtf(kvp_state_t *st, int set, int way)
{
    uint8_t o[KVP_WAYS];
    int i, k = 1;
    o[0] = (uint8_t)way;
    for (i = 0; i < KVP_WAYS; i++)
        if (st->order[set][i] != (uint8_t)way)
            o[k++] = st->order[set][i];
    for (i = 0; i < KVP_WAYS; i++)
        st->order[set][i] = o[i];
}

static int tlb_probe(const kvp_state_t *st, uint32_t key, uint32_t *phys)
{
    int set = (int)(key & (uint32_t)(KVP_SETS - 1));
    uint32_t tag = key >> KVP_SET_BITS;
    int w;
    for (w = 0; w < KVP_WAYS; w++) {
        int e = set * KVP_WAYS + w;
        if (st->valid[e] && st->tag[e] == tag) {
            if (phys) *phys = st->phys[e];
            return w;
        }
    }
    return -1;
}

static void tlb_touch(kvp_state_t *st, uint32_t key, int way)
{
    mtf(st, (int)(key & (uint32_t)(KVP_SETS - 1)), way);
}

static void tlb_fill(kvp_state_t *st, uint32_t key, uint32_t phys)
{
    int set = (int)(key & (uint32_t)(KVP_SETS - 1));
    uint32_t tag = key >> KVP_SET_BITS;
    int w, victim = -1;

    for (w = 0; w < KVP_WAYS; w++)                /* lowest invalid way first */
        if (!st->valid[set * KVP_WAYS + w]) { victim = w; break; }
    if (victim < 0)                               /* else the LRU way         */
        victim = st->order[set][KVP_WAYS - 1];

    st->valid[set * KVP_WAYS + victim] = 1;
    st->tag  [set * KVP_WAYS + victim] = tag;
    st->phys [set * KVP_WAYS + victim] = phys;
    mtf(st, set, victim);
}

static void tlb_inv(kvp_state_t *st, uint32_t key)
{
    int way = tlb_probe(st, key, 0);
    if (way >= 0)
        st->valid[(int)(key & (uint32_t)(KVP_SETS - 1)) * KVP_WAYS + way] = 0;
}

/* ---------------- state / pool ---------------- */

void kvp_soft_reset(kvp_state_t *st)
{
    tlb_reset(st);
    st->sp = 0;
    st->reqs = st->xlates = st->hits = st->misses = 0;
    st->allocs = st->frees = st->errs = 0;
    st->sticky_oom = 0;
}

void kvp_push_free(kvp_state_t *st, uint32_t blk)
{
    if (st->sp < KVP_FREE_DEPTH)
        st->stack[st->sp++] = blk & KVP_PHYS_MASK;
}

/* ---------------- one translation ---------------- */

static uint32_t bt_word(uint32_t seq, uint32_t idx)
{
    return (uint32_t)KVP_BT_BASE_W + seq * (uint32_t)KVP_BT_STRIDE + idx;
}

static uint32_t make_key(uint32_t seq, uint32_t idx)
{
    return (seq << KVP_LOG_W) | (idx & 0xFFFFu);
}

/* returns 1 if the (range) walk must stop after this item */
static int translate(kvp_state_t *st, uint32_t *mem, uint32_t seq, uint32_t idx,
                     int noalloc, uint32_t *res)
{
    uint32_t key = make_key(seq, idx);
    uint32_t phys = 0, entry, blk;
    int way;

    st->xlates++;
    way = tlb_probe(st, key, &phys);
    if (way >= 0) {
        st->hits++;
        tlb_touch(st, key, way);
        *res = kvp_res(F_HIT, phys);
        return 0;
    }
    st->misses++;

    entry = mem[bt_word(seq, idx)];
    if (entry != KVP_BT_INVALID) {
        tlb_fill(st, key, entry & KVP_PHYS_MASK);
        *res = kvp_res(0, entry & KVP_PHYS_MASK);
        return 0;
    }
    if (noalloc) {
        st->errs++;
        *res = kvp_res(F_EINVAL, 0);
        return 0;
    }
    if (st->sp == 0) {                            /* pool exhausted */
        st->errs++;
        st->sticky_oom = 1;
        *res = kvp_res(F_EOOM, 0);
        return 1;
    }
    blk = st->stack[--st->sp];
    st->allocs++;
    mem[bt_word(seq, idx)] = blk;
    tlb_fill(st, key, blk);
    *res = kvp_res(F_ALLOC, blk);
    return 0;
}

/* ---------------- one batch ---------------- */

uint32_t kvp_run_batch(kvp_state_t *st, uint32_t *mem,
                       uint32_t req_base_w, uint32_t res_base_w, uint32_t nreq)
{
    uint32_t r, nres = 0;

    for (r = 0; r < nreq; r++) {
        uint32_t word = mem[req_base_w + r];
        uint32_t op   = word >> 28;
        uint32_t seq  = (word >> 16) & 0xFFFu;
        uint32_t arg  = word & 0xFFFFu;
        uint32_t res  = 0, i;

        st->reqs++;

        switch (op) {
        case OP_XLATE:
        case OP_NOALLOC:
            translate(st, mem, seq, arg, op == OP_NOALLOC, &res);
            mem[res_base_w + nres++] = res;
            break;

        case OP_RANGE:
            for (i = 0; i < arg; i++) {
                int stop = translate(st, mem, seq, i, 0, &res);
                mem[res_base_w + nres++] = res;
                if (stop) break;                  /* the sequence cannot grow */
            }
            break;

        case OP_FREE: {
            uint32_t freed = 0;
            for (i = 0; i < arg; i++) {
                uint32_t a = bt_word(seq, i);
                if (mem[a] != KVP_BT_INVALID) {
                    kvp_push_free(st, mem[a] & KVP_PHYS_MASK);
                    tlb_inv(st, make_key(seq, i));
                    mem[a] = KVP_BT_INVALID;
                    st->frees++;
                    freed++;
                }
            }
            mem[res_base_w + nres++] = kvp_res(F_FREED, freed);
            break;
        }

        case OP_FLUSH:
            tlb_reset(st);
            mem[res_base_w + nres++] = kvp_res(F_FLUSHED, 0);
            break;

        default:
            st->errs++;
            mem[res_base_w + nres++] = kvp_res(F_EBADOP, 0);
            break;
        }
    }
    return nres;
}
