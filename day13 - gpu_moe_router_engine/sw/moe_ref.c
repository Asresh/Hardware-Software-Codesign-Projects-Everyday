/* ============================================================================
 * moe_ref.c - bit-exact golden model for the MoE router / gating engine.
 *
 * For one token of MOE_E expert logits it:
 *   1. selects the top-K experts (strict-greater compare, lowest-index ties);
 *   2. computes exp(logit_j - max) in Q.16 from the shared LUT;
 *   3. renormalises the K exps to gate weights (softmax over the selected set);
 *   4. applies per-expert capacity: a slot whose expert is already at capacity
 *      is dropped (weight forced 0, counter not incremented, overflow flagged);
 *   5. updates per-expert load counters and running statistics.
 *
 * Every arithmetic step is the exact integer operation the RTL performs.
 * ==========================================================================*/
#include "moe.h"

void moe_route(moe_state_t *st, const int16_t logit[MOE_E],
               uint16_t token_id, const uint32_t lut[MOE_LUT_N],
               moe_record_t *rec)
{
    int sel[MOE_K];
    int taken[MOE_E];
    int i, k;

    for (i = 0; i < MOE_E; i++) taken[i] = 0;

    /* ---- top-K selection: repeated argmax with lowest-index tie-break ---- */
    for (k = 0; k < MOE_K; k++) {
        int best = -1;
        for (i = 0; i < MOE_E; i++) {
            if (taken[i]) continue;
            if (best < 0 || logit[i] > logit[best]) best = i;  /* strict > */
        }
        sel[k] = best;
        taken[best] = 1;
    }

    int16_t maxv = logit[sel[0]];      /* top-0 is the maximum logit          */

    /* ---- exp(logit_j - max) and denominator over the selected set -------- */
    uint32_t expv[MOE_K];
    uint32_t den = 0;
    for (k = 0; k < MOE_K; k++) {
        int32_t d = (int32_t)logit[sel[k]] - (int32_t)maxv;   /* <= 0         */
        expv[k] = moe_exp_q16(d, lut);
        den += expv[k];
    }

    /* ---- renormalise to gate weights, then apply capacity ---------------- */
    rec->token_id = token_id;
    rec->routed   = 0;
    for (k = 0; k < MOE_K; k++) {
        uint32_t w = moe_gate_q16(expv[k], den);
        int e = sel[k];
        rec->expert[k] = (uint8_t)e;
        if (st->load[e] < st->cap) {
            st->load[e]++;
            rec->weight[k]   = w;
            rec->overflow[k] = 0;
            rec->routed++;
            st->routed++;
        } else {
            rec->weight[k]   = 0;      /* dropped: over capacity              */
            rec->overflow[k] = 1;
            st->overflows++;
        }
    }
    st->tokens++;
}
