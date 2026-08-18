/* Author: Asresh */
/* Deterministic vector generator; model and scalar baseline both process every request. */
#include "replay_guard.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define COUNT 320u
static uint32_t state=0x28a5f00du;
static uint32_t rnd(void){state^=state<<13;state^=state>>17;state^=state<<5;return state;}
static struct rg_request history[COUNT];
int main(int argc,char **argv){
 char path[512];FILE *f;struct rg_model m;struct rg_request q;struct rg_result res;uint64_t base=0;uint32_t i;
 if(argc!=2)return 2;
 if(snprintf(path,sizeof(path),"%s/vectors.txt",argv[1])<0)return 2;
 f=fopen(path,"w");
 if(!f){perror(path);return 2;}
 rg_model_reset(&m);
 fprintf(f,"# Author: Asresh\n");
 fprintf(f,"%u %020llu %010u %010u %010u\n",COUNT,0ull,0u,0u,0u);
 for(i=0;i<COUNT;i++){
  memset(&q,0,sizeof(q));q.op=RG_CHECK;q.context=(uint8_t)(rnd()%RG_CONTEXTS);q.epoch=(uint16_t)(1u+rnd()%16u);q.nonce[0]=rnd();q.nonce[1]=rnd();q.nonce[2]=rnd();q.nonce[3]=rnd();
  if(i==0){q.context=0;q.epoch=1;q.nonce[0]=0; q.nonce[1]=0;q.nonce[2]=0;q.nonce[3]=0;}
  else if(i==1)q=history[0];
  else if(i==2){q.op=RG_SET_EPOCH;q.context=0;q.epoch=5;}
  else if(i==3){q.context=0;q.epoch=4;q.nonce[0]=1;}
  else if(i==4){q.context=0;q.epoch=5;q.nonce[0]=1;}
  else if(i==5){q.op=RG_FLUSH_CONTEXT;q.context=0;}
  else if(i==6)q=history[4];
  else if(i==7){q.op=RG_FLUSH_ALL;}
  else if(i%41u==0){q.op=RG_SET_EPOCH;q.epoch=(uint16_t)(20u+i);}
  else if(i%67u==0){q.op=RG_FLUSH_CONTEXT;}
  else if(i%89u==0){q.op=RG_FLUSH_ALL;}
  else if(i>20&&i%7u==0)q=history[i-5u];
  base+=rg_baseline_cycles(&q,&m);res=rg_model_step(&m,&q);history[i]=q;
  fprintf(f,"%u %u %u %08x %08x %08x %08x %u %u %u\n",q.op,q.context,q.epoch,q.nonce[0],q.nonce[1],q.nonce[2],q.nonce[3],res.accept,res.reason,res.slot);
 }
 if(fseek(f,0,SEEK_SET)!=0)return 2;
 fprintf(f,"# Author: Asresh\n%u %020llu %010u %010u %010u\n",COUNT,(unsigned long long)base,m.accepted,m.replays,m.stale);
 if(fclose(f)!=0)return 2;
 printf("generated %u requests; scalar baseline %llu cycles\n",COUNT,(unsigned long long)base);
 return 0;
}
