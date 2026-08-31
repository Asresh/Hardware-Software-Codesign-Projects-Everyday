/* Author: Asresh */
#include "ml_topk.h"
void topk_reference(const int16_t scores[TOPK_LANES], struct topk_result *out) {
    uint32_t a;
    out->top[0].value = INT16_MIN; out->top[1].value = INT16_MIN;
    out->top[0].index = UINT8_MAX; out->top[1].index = UINT8_MAX;
    out->top[0].reserved = 0; out->top[1].reserved = 0;
    for (a=0;a<TOPK_LANES;a++) {
        if (scores[a] > out->top[0].value ||
            (scores[a] == out->top[0].value && a < out->top[0].index)) {
            out->top[1]=out->top[0];
            out->top[0].value=scores[a]; out->top[0].index=(uint8_t)a;
        } else if (scores[a] > out->top[1].value ||
                   (scores[a] == out->top[1].value && a < out->top[1].index)) {
            out->top[1].value=scores[a]; out->top[1].index=(uint8_t)a;
        }
    }
}
