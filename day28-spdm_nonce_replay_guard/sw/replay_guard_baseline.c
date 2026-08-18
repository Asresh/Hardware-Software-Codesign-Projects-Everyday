/* Author: Asresh */
/* Scalar MCU cost model: load/validate request, scan each live CAM candidate, then update. */
#include "replay_guard.h"
uint64_t rg_baseline_cycles(const struct rg_request *q,const struct rg_model *before){
 uint64_t cycles=18; size_t i; if(q->op!=RG_CHECK)return 22;
 for(i=0;i<RG_ENTRIES;i++){cycles+=3;if(before->entries[i].valid){cycles+=5;if(before->entries[i].context==q->context&&before->entries[i].epoch==q->epoch)cycles+=10;}}
 return cycles+14;
}
