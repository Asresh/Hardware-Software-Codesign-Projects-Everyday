/* Author: Asresh */
#include "ras_graph.h"
uint64_t ras_scalar_baseline(const uint16_t row[RAS_NODES],uint16_t seed,uint16_t *out){
 uint16_t reached=seed,frontier=seed;uint64_t cycles=0u;
 for(;;){uint16_t neighbors=0u;size_t s,d;
  for(d=0;d<RAS_NODES;d++){uint16_t hit=0u;for(s=0;s<RAS_NODES;s++){cycles+=2u;if((frontier&(uint16_t)(1u<<s))!=0u&&(row[s]&(uint16_t)(1u<<d))!=0u)hit=1u;}if(hit!=0u)neighbors=(uint16_t)(neighbors|(uint16_t)(1u<<d));}
  cycles+=8u;
  frontier=(uint16_t)(neighbors&(uint16_t)~reached);
  if(frontier==0u){*out=reached;return cycles;}
  reached=(uint16_t)(reached|frontier);
 }
}
