/* Author: Asresh */
#include "pcie_reorder.h"
#include <inttypes.h>
#include <stdio.h>
int main(void) {
    uint32_t regs[9]={0}, state=UINT32_C(39); pcr_device dev={regs};
    pcr_result results[320]; size_t i;
    if (pcr_configure(&dev,320u)!=0 || regs[PCR_TARGET]!=320u || regs[PCR_CTRL]!=1u) return 1;
    for(i=0;i<320u;i++) {
        state=state*UINT32_C(1664525)+UINT32_C(1013904223);
        results[i]=pcr_reference((uint16_t)i,state);
        if(results[i].id!=i || results[i].status!=(i&3u)) return 2;
    }
    pcr_ack_irq(&dev); if(regs[PCR_CTRL]!=5u) return 3;
    printf("software PASS: vectors=320 checksum=0x%016" PRIx64 "\n",pcr_checksum(results,320u));
    return 0;
}
