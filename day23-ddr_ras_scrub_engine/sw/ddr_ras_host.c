/* Author: Asresh. Reproducible 304-vector generator and reference checker. */
#include "ddr_ras.h"
#include <inttypes.h>
#include <stdio.h>
static uint32_t rng_state=UINT32_C(0x23a5c7e9);static uint32_t rnd(void){rng_state=rng_state*UINT32_C(1664525)+UINT32_C(1013904223);return rng_state;}
int main(int argc,char**argv){char path[512];FILE*f;unsigned i;if(argc!=2)return 2;if(snprintf(path,sizeof path,"%s/vectors.txt",argv[1])>=(int)sizeof path)return 2;f=fopen(path,"w");if(!f)return 2;fprintf(f,"304\n");for(i=0;i<304;++i){uint32_t d=i==0?0u:i==1?UINT32_MAX:rnd();uint64_t clean=ras_encode(d),noisy=clean,expect;unsigned fixed,bad,b0=(i*17u)%39u,b1=(i*29u+7u)%39u;if(i%4u==1u)noisy^=UINT64_C(1)<<b0;else if(i%4u==2u){if(b1==b0)b1=(b1+1u)%39u;noisy^=(UINT64_C(1)<<b0)|(UINT64_C(1)<<b1);}else if(i%4u==3u)noisy^=UINT64_C(1)<<38;expect=ras_check(noisy,&fixed,&bad);fprintf(f,"%010"PRIx64" %010"PRIx64" %u %u\n",noisy,expect,fixed,bad);}fclose(f);printf("generated 304 SECDED vectors; scalar baseline=%"PRIu64" cycles\n",ras_baseline_cycles(304));return 0;}
