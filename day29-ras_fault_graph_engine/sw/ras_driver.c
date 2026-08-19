/* Author: Asresh */
#include "ras_graph.h"
enum { CTRL=0,SEED=1,ROW_INDEX=2,ROW_DATA=3,RESULT=4 };
int ras_run(struct ras_mmio *dev,const uint16_t row[RAS_NODES],uint16_t seed,uint16_t *reached,uint32_t timeout){
 size_t i;if(dev==NULL||dev->base==NULL||row==NULL||reached==NULL||seed==0u)return -1;
 for(i=0;i<RAS_NODES;i++){dev->base[ROW_INDEX]=(uint32_t)i;dev->base[ROW_DATA]=row[i];}
 dev->base[SEED]=seed;dev->base[CTRL]=3u;
 while(timeout!=0u){if((dev->base[CTRL]&8u)!=0u){*reached=(uint16_t)dev->base[RESULT];dev->base[CTRL]=10u;return 0;}timeout--;}
 return -2;
}
