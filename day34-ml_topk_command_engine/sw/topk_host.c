/* Author: Asresh */
#include "ml_topk.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define VECTOR_COUNT 320u
struct mock { uint8_t memory[16384]; uint32_t reg[8]; };
static uint32_t rng_state=0x34c0ffeeu;
static uint32_t next_random(void){rng_state=rng_state*1664525u+1013904223u;return rng_state;}
static void mw(void *p,uint32_t a,uint32_t v){struct mock*m=p;m->reg[a/4u]=v;
 if(a==TOPK_REG_IRQ)m->reg[1]&=~TOPK_STATUS_IRQ;
 if(a==TOPK_REG_CONTROL&&(v&TOPK_CONTROL_START)){
  uint32_t n=m->reg[TOPK_REG_COUNT/4u],s=m->reg[TOPK_REG_SOURCE/4u],d=m->reg[TOPK_REG_DEST/4u],i;
  for(i=0;i<n;i++){struct topk_result r;topk_reference((const int16_t *)(void *)&m->memory[s+i*16u],&r);memcpy(&m->memory[d+i*8u],&r,sizeof r);}
  m->reg[1]=TOPK_STATUS_IRQ; }}
static uint32_t mr(void*p,uint32_t a){return ((struct mock*)p)->reg[a/4u];}
static int mto(void*p,uint32_t a,const void*s,size_t n){struct mock*m=p;if((size_t)a+n>sizeof m->memory)return-1;memcpy(&m->memory[a],s,n);return 0;}
static int mfrom(void*p,void*d,uint32_t a,size_t n){struct mock*m=p;if((size_t)a+n>sizeof m->memory)return-1;memcpy(d,&m->memory[a],n);return 0;}
int main(void){int16_t scores[VECTOR_COUNT][TOPK_LANES];struct topk_result ref[VECTOR_COUNT],base,got[VECTOR_COUNT];
 struct mock mock_device={{0},{0}};struct topk_io io={&mock_device,mw,mr,mto,mfrom};FILE*f;uint32_t n,j,baseline=0;
 static const int16_t directed[8][8]={{0,0,0,0,0,0,0,0},{INT16_MIN,INT16_MAX,0,-1,1,7,-7,42},
 {9,9,9,9,9,9,9,9},{INT16_MAX,INT16_MAX,INT16_MIN,INT16_MIN,3,2,1,0},
 {-8,-7,-6,-5,-4,-3,-2,-1},{7,6,5,4,3,2,1,0},{0,-1,0,-1,0,-1,0,-1},{4,8,15,16,23,42,42,1}};
 for(n=0;n<VECTOR_COUNT;n++)for(j=0;j<TOPK_LANES;j++)scores[n][j]=(n<8)?directed[n][j]:(int16_t)(next_random()>>16);
 for(n=0;n<VECTOR_COUNT;n++){topk_reference(scores[n],&ref[n]);baseline+=topk_baseline(scores[n],&base);
  if(memcmp(&base,&ref[n],sizeof base)){fprintf(stderr,"baseline mismatch %u\n",n);return 1;}}
 if(topk_run(&io,0x100u,0x1800u,&scores[0][0],got,VECTOR_COUNT,1000u)){fprintf(stderr,"driver integration failed\n");return 1;}
 if(memcmp(got,ref,sizeof got)){fprintf(stderr,"driver result mismatch\n");return 1;}
 f=fopen("tb/vectors.txt","w");if(!f){perror("tb/vectors.txt");return 1;}
 if(fprintf(f,"%u %u\n",VECTOR_COUNT,baseline)<0)return 1;
 for(n=0;n<VECTOR_COUNT;n++){for(j=0;j<TOPK_LANES;j++)if(fprintf(f,"%d ",scores[n][j])<0)return 1;
  if(fprintf(f,"%d %u %d %u\n",ref[n].top[0].value,ref[n].top[0].index,ref[n].top[1].value,ref[n].top[1].index)<0)return 1;}
 if(fclose(f)){perror("vectors close");return 1;}
 printf("generated %u vectors; driver/reference/baseline agree; baseline cycles=%u\n",VECTOR_COUNT,baseline);return 0;}
