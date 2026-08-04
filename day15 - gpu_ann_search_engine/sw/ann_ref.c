/* ============================================================================
 * ann_ref.c - bit-exact reference model for the ANN top-K search engine.
 *
 * Pure integer arithmetic, identical in every respect to the RTL datapath:
 *   - squared-L2 :  score = sum_i (q_i - x_i)^2          (kept smallest)
 *   - inner-prod :  score = sum_i (q_i * x_i)            (kept largest)
 * Both fit a signed 32-bit accumulator for ANN_D<=64 int8 elements.
 *
 * The top-K selection uses the SAME stable rule as the hardware insertion
 * network: results are held best->worst; database vectors are visited in
 * ascending id order; on a tie the earlier (smaller-id) vector ranks first,
 * so a new candidate is inserted AFTER every stored entry that is at least as
 * good.  This makes the golden results reproducible to the bit.
 * ==========================================================================*/
#include "ann.h"

/* per-vector score, exactly as the SIMD lanes + adder tree + accumulator do it */
static int32_t score_vec(int metric, const int8_t *q, const int8_t *x)
{
    int32_t acc = 0;
    int i;
    for (i = 0; i < ANN_D; i++) {
        if (metric == ANN_METRIC_L2) {
            int32_t d = (int32_t)q[i] - (int32_t)x[i];   /* [-255,255]        */
            acc += d * d;                                /* >=0               */
        } else {
            acc += (int32_t)q[i] * (int32_t)x[i];        /* signed dot        */
        }
    }
    return acc;
}

/* "is the stored slot at least as good as the new candidate?" - a stored slot
 * that is at-least-as-good must stay ahead of the newcomer (stable on ties). */
static int slot_before_new(int metric, int32_t slot, int32_t cand)
{
    return (metric == ANN_METRIC_L2) ? (slot <= cand) : (slot >= cand);
}

int ann_topk_ref(int metric, const int8_t *q, const int8_t *db, int n,
                 ann_entry_t *out)
{
    int32_t sent = (metric == ANN_METRIC_L2) ? SCORE_SENT_L2 : SCORE_SENT_IP;
    int count = 0;               /* valid entries currently held             */
    int v, j;

    for (j = 0; j < ANN_K; j++) { out[j].score = sent; out[j].id = ID_SENT; }

    for (v = 0; v < n; v++) {
        int32_t s = score_vec(metric, q, db + (long)v * ANN_D);
        int pos = 0;
        /* insertion position = number of held entries at least as good */
        for (j = 0; j < count; j++)
            if (slot_before_new(metric, out[j].score, s)) pos++;
            else break;                       /* held list is sorted          */
        if (pos >= ANN_K) continue;           /* not good enough to make top-K */
        /* shift worse entries down by one, drop the tail if the list is full */
        for (j = (count < ANN_K ? count : ANN_K - 1); j > pos; j--)
            out[j] = out[j - 1];
        out[pos].score = s;
        out[pos].id    = v;
        if (count < ANN_K) count++;
    }
    return (n < ANN_K) ? n : ANN_K;
}
