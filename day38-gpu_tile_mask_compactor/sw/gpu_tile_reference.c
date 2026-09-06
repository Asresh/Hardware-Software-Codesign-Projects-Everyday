/* Author: Asresh */
#include "gpu_tile_mask.h"
gtm_result gtm_reference(uint64_t mask, unsigned sparse_threshold) {
    gtm_result r={0,0,0,1,1}; unsigned i;
    for (i=0;i<64u;i++) if ((mask >> i) & UINT64_C(1)) {
        if (r.empty) r.first=(uint8_t)i;
        r.last=(uint8_t)i; r.count++; r.empty=0;
    }
    r.sparse=(uint8_t)(r.count<=sparse_threshold);
    return r;
}
uint32_t gtm_pack(gtm_result r) {
    return (uint32_t)r.count | ((uint32_t)r.first<<7) | ((uint32_t)r.last<<13) |
           ((uint32_t)r.empty<<19) | ((uint32_t)r.sparse<<20);
}
