/* Author: Asresh */
#include "ml_topk.h"
int topk_run(const struct topk_io *io,uint32_t source,uint32_t destination,
             const int16_t *scores,struct topk_result *results,size_t count,uint32_t timeout){
    uint32_t status;
    if(!io||!io->write32||!io->read32||!io->copy_to_device||!io->copy_from_device||
       !scores||!results||count==0||count>1024||count>UINT32_MAX/16u||
       (source&3u)||(destination&3u)||timeout==0)return -1;
    if(io->copy_to_device(io->context,source,scores,count*TOPK_LANES*sizeof(*scores)))return -2;
    io->write32(io->context,TOPK_REG_SOURCE,source);
    io->write32(io->context,TOPK_REG_DEST,destination);
    io->write32(io->context,TOPK_REG_COUNT,(uint32_t)count);
    io->write32(io->context,TOPK_REG_CONTROL,TOPK_CONTROL_START|TOPK_CONTROL_IRQ_ENABLE);
    do { status=io->read32(io->context,TOPK_REG_STATUS); if(status&TOPK_STATUS_IRQ)break; } while(--timeout);
    if(!(status&TOPK_STATUS_IRQ))return -3;
    if(status&TOPK_STATUS_ERROR)return -4;
    if(io->copy_from_device(io->context,results,destination,count*sizeof(*results)))return -5;
    io->write32(io->context,TOPK_REG_IRQ,1u);
    return 0;
}
