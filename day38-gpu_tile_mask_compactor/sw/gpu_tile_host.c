/* Author: Asresh */
#include "gpu_tile_mask.h"
#include <inttypes.h>
#include <stdio.h>
int main(void) {
    uint32_t regs[8]={0}; gtm_device dev={regs}; uint64_t x=UINT64_C(38), checksum=0; unsigned i;
    if (gtm_configure(&dev,8u)!=0 || regs[GTM_THRESHOLD]!=8u || regs[GTM_CTRL]!=1u) return 1;
    for(i=0;i<320u;i++) {
        gtm_result r;
        x=x*UINT64_C(6364136223846793005)+UINT64_C(1442695040888963407);
        r=gtm_reference(x,8u); checksum=(checksum<<1)^gtm_pack(r)^x;
        if (r.count>64u || r.first>r.last) return 2;
    }
    gtm_ack_irq(&dev); if(regs[GTM_CTRL]!=5u) return 3;
    printf("software PASS: vectors=320 threshold=8 checksum=0x%016" PRIx64 "\n",checksum);
    return 0;
}
