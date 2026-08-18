/* Author: Asresh */
/* Portable mailbox driver: move request, ring doorbell, wait IRQ status, consume and W1C. */
#include "replay_guard.h"
int rg_submit(void *c,rg_write_fn w,rg_read_fn r,const struct rg_request *q,struct rg_result *out,uint32_t timeout){
 uint32_t v,i; w(c,RG_META,(uint32_t)q->context|((uint32_t)q->epoch<<5));for(i=0;i<4;i++)w(c,RG_NONCE0+4*i,q->nonce[i]);w(c,RG_CTRL,2u|1u|((uint32_t)q->op<<8));
 do{v=r(c,RG_CTRL);if(v&8u)break;}while(timeout--);if(!(v&8u))return -1;v=r(c,RG_RESULT);out->accept=(uint8_t)(v&1u);out->reason=(uint8_t)((v>>1)&7u);out->slot=(uint8_t)((v>>4)&31u);w(c,RG_CTRL,10u);return 0;
}
