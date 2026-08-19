/* Author: Asresh */
#include "ras_graph.h"
uint16_t ras_reference(const uint16_t row[RAS_NODES],uint16_t seed,uint32_t *iterations){
 uint16_t reached=seed,frontier=seed;
 for(;;){uint16_t neighbors=0u;size_t s;(*iterations)++;
  for(s=0;s<RAS_NODES;s++)if((frontier&(uint16_t)(1u<<s))!=0u)neighbors=(uint16_t)(neighbors|row[s]);
  frontier=(uint16_t)(neighbors&(uint16_t)~reached);
  if(frontier==0u)return reached;
  reached=(uint16_t)(reached|frontier);
 }
}
