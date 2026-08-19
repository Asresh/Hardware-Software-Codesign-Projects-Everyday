/* Author: Asresh */
#include "ras_graph.h"
#include <stdio.h>
#include <stdlib.h>
static uint32_t state=0x29c0ffeeu;
static uint32_t rnd(void){state=state*1664525u+1013904223u;return state;}
static void make_case(unsigned n,struct ras_case *c){size_t i;for(i=0;i<RAS_NODES;i++)c->row[i]=0u;
 if(n==0u)c->seed=1u;
 else if(n==1u){for(i=0;i+1u<RAS_NODES;i++)c->row[i]=(uint16_t)(1u<<(i+1u));c->seed=1u;}
 else if(n==2u){for(i=0;i<RAS_NODES;i++)c->row[i]=0xffffu;c->seed=0x8000u;}
 else if(n==3u){for(i=0;i<RAS_NODES;i++)c->row[i]=(uint16_t)(1u<<i);c->seed=0x8421u;}
 else if(n==4u){c->row[0]=6u;c->row[1]=8u;c->row[2]=16u;c->row[3]=32u;c->seed=1u;}
 else if(n==5u){c->row[15]=1u;c->row[0]=0x8000u;c->seed=0x8000u;}
 else if(n==6u){c->seed=0xffffu;}
 else {for(i=0;i<RAS_NODES;i++){uint32_t r=rnd();c->row[i]=(uint16_t)(r^(r>>16));}c->seed=(uint16_t)(1u<<(rnd()%RAS_NODES));}
 c->iterations=0u;c->reached=ras_reference(c->row,c->seed,&c->iterations);
}
int main(int argc,char **argv){char path[512];FILE *f;int written;unsigned n;uint64_t baseline=0u;struct ras_case cases[320];
 if(argc!=2){fprintf(stderr,"usage: %s output-directory\n",argv[0]);return 2;}
 for(n=0;n<320u;n++){uint16_t scalar;make_case(n,&cases[n]);baseline+=ras_scalar_baseline(cases[n].row,cases[n].seed,&scalar);if(scalar!=cases[n].reached)return 3;}
 written=snprintf(path,sizeof(path),"%s/vectors.txt",argv[1]);
 if(written<0||(size_t)written>=sizeof(path))return 2;
 f=fopen(path,"w");
 if(f==NULL){perror(path);return 2;}
 fprintf(f,"320 %llu\n",(unsigned long long)baseline);for(n=0;n<320u;n++){size_t i;struct ras_case *c=&cases[n];
  fprintf(f,"%04x",c->seed);for(i=0;i<RAS_NODES;i++)fprintf(f," %04x",c->row[i]);fprintf(f," %04x %u\n",c->reached,c->iterations);}
 if(fclose(f)!=0)return 2;
 printf("generated 320 vectors; scalar baseline=%llu cycles\n",(unsigned long long)baseline);return 0;
}
