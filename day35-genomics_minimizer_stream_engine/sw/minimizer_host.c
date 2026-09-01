/* Author: Asresh */
#include "minimizer.h"
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    uint32_t regs[8]={0}, kmers[320]; minimizer_result out[320]; minimizer_dev dev={regs}; unsigned i; uint32_t s=35;
    kmers[0]=0; kmers[1]=UINT32_MAX; kmers[2]=UINT32_C(0x1b1b1b1b); kmers[3]=UINT32_C(0xe4e4e4e4);
    for(i=4;i<320;i++){ s=s*UINT32_C(1664525)+UINT32_C(1013904223); kmers[i]=s; }
    minimizer_configure(&dev,UINT32_C(0x35c0ffee));
    if(regs[MIN_SEED]!=UINT32_C(0x35c0ffee) || minimizer_reference(kmers,320,16,8,regs[MIN_SEED],out)!=313) return 1;
    for(i=0;i<313;i++) if(out[i].position>i+7) return 2;
    printf("software PASS: 320 kmers, 313 minimizers, seed=0x%08x\n",regs[MIN_SEED]);
    return 0;
}
