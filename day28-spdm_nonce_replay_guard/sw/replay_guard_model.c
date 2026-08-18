/* Author: Asresh */
#include "replay_guard.h"
#include <string.h>
void rg_model_reset(struct rg_model *m){ memset(m,0,sizeof(*m)); }
static int same(const struct rg_entry *e,const struct rg_request *q){return e->valid&&e->context==q->context&&e->epoch==q->epoch&&!memcmp(e->nonce,q->nonce,sizeof(e->nonce));}
struct rg_result rg_model_step(struct rg_model *m,const struct rg_request *q){
 struct rg_result r={1,RG_ACCEPT,0}; size_t i; int match=-1,free_slot=-1;
 for(i=0;i<RG_ENTRIES;i++){if(same(&m->entries[i],q)&&match<0)match=(int)i;if(!m->entries[i].valid&&free_slot<0)free_slot=(int)i;}
 if(q->op==RG_CHECK){
  if(q->epoch<m->floor[q->context]){r.accept=0;r.reason=RG_STALE_EPOCH;m->stale++;return r;}
  if(match>=0){r.accept=0;r.reason=RG_REPLAY;r.slot=(uint8_t)match;m->replays++;return r;}
  r.slot=(uint8_t)(free_slot>=0?free_slot:m->replace); if(free_slot<0)m->replace=(uint8_t)((m->replace+1u)%RG_ENTRIES);
  m->entries[r.slot].valid=1;m->entries[r.slot].context=q->context;m->entries[r.slot].epoch=q->epoch;memcpy(m->entries[r.slot].nonce,q->nonce,sizeof(q->nonce));m->accepted++;
 }else if(q->op==RG_SET_EPOCH){m->floor[q->context]=q->epoch;r.reason=RG_EPOCH_SET;for(i=0;i<RG_ENTRIES;i++)if(m->entries[i].valid&&m->entries[i].context==q->context)m->entries[i].valid=0;}
 else if(q->op==RG_FLUSH_CONTEXT){r.reason=RG_FLUSHED;for(i=0;i<RG_ENTRIES;i++)if(m->entries[i].valid&&m->entries[i].context==q->context)m->entries[i].valid=0;}
 else {r.reason=RG_FLUSHED;for(i=0;i<RG_ENTRIES;i++)m->entries[i].valid=0;}
 return r;
}
