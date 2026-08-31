/* Author: Asresh */
#include "ml_topk.h"
/* Insertion sort models a small embedded runtime selecting two classes. The
 * returned instruction-cycle count uses the measured target loop accounting:
 * five cycles per compare/branch/move slot plus fixed load/store overhead. */
uint32_t topk_baseline(const int16_t scores[TOPK_LANES], struct topk_result *out) {
    int16_t values[TOPK_LANES]; uint8_t indices[TOPK_LANES];
    uint32_t i,j,comparisons=0;
    for(i=0;i<TOPK_LANES;i++){values[i]=scores[i];indices[i]=(uint8_t)i;}
    for(i=1;i<TOPK_LANES;i++){
        int16_t v=values[i];uint8_t ix=indices[i];j=i;
        while(j>0){comparisons++;
            if(values[j-1]>v||(values[j-1]==v&&indices[j-1]<ix))break;
            values[j]=values[j-1];indices[j]=indices[j-1];j--;
        } values[j]=v;indices[j]=ix;
    }
    out->top[0].value=values[0];out->top[0].index=indices[0];out->top[0].reserved=0;
    out->top[1].value=values[1];out->top[1].index=indices[1];out->top[1].reserved=0;
    return 64u + comparisons*5u;
}
