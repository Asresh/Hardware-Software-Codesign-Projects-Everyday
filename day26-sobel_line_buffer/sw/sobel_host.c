/* Author: Asresh */
/* Deterministic workload generator: 16 directed edge pixels plus 304 seeded random pixels. */
#include "sobel.h"
#include <stdio.h>
#include <stdlib.h>
static uint32_t rng=0x2608a5c3u;
static uint32_t next_u32(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
int main(int argc,char **argv){
 enum{W=20,H=16,N=W*H,OUT=(W-2)*(H-2)};uint8_t src[N],gold[OUT];
 static const uint8_t directed[16]={0,255,0,255,255,0,255,0,0,0,0,255,255,255,128,127};
 FILE *f;int x,y,k=0;if(argc!=2){fprintf(stderr,"usage: %s vector-dir\n",argv[0]);return 2;}
 for(k=0;k<16;k++)src[k]=directed[k];for(;k<N;k++)src[k]=(uint8_t)next_u32();
 k=0;for(y=0;y<H-2;y++)for(x=0;x<W-2;x++)gold[k++]=sobel_reference_pixel(&src[y*W+x],W);
 {char path[512];if(snprintf(path,sizeof(path),"%s/vectors.txt",argv[1])<0)return 3;f=fopen(path,"w");}
 if(!f){perror("vectors");return 4;}fprintf(f,"%d %d %d %llu\n",W,H,OUT,(unsigned long long)sobel_baseline_cycles(W,H));
 for(k=0;k<N;k++)fprintf(f,"%u\n",(unsigned)src[k]);for(k=0;k<OUT;k++)fprintf(f,"%u\n",(unsigned)gold[k]);
 if(fclose(f)!=0)return 5;printf("generated %d input pixels (%d random + 16 directed), %d references\n",N,N-16,OUT);return 0;
}
