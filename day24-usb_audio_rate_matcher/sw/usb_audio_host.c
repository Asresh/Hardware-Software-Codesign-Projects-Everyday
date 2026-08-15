/* Author: Asresh
 * Diagram: seeded cases -> bit-exact model -> vector file + baseline metric
 */
#include "usb_audio.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
static uint32_t rng=UINT32_C(0x24a0d10);
static uint32_t next_u32(void){ rng=rng*UINT32_C(1664525)+UINT32_C(1013904223); return rng; }
int main(int argc,char **argv){
    enum { N=320 }; const uint16_t target=256,gain=192;
    const char *dir=argc>1?argv[1]:"tb/vectors"; char path[512];
    int n=snprintf(path,sizeof path,"%s/vectors.txt",dir);
    if(n<0 || (size_t)n>=sizeof path) return 2;
    FILE *f=fopen(path,"w"); if(!f){perror(path);return 2;}
    if(fprintf(f,"%d %u %u\n",N,target,gain)<0) return 2;
    for(int i=0;i<N;i++){
        struct ua_sample s;
        if(i==0){s=(struct ua_sample){0,0,target};}
        else if(i==1){s=(struct ua_sample){INT16_MIN,INT16_MAX,0};}
        else if(i==2){s=(struct ua_sample){INT16_MAX,INT16_MIN,65535};}
        else if(i==3){s=(struct ua_sample){-1,1,target};}
        else if(i==4){s=(struct ua_sample){1234,-2345,target+1};}
        else if(i==5){s=(struct ua_sample){-30000,30000,target-1};}
        else {s.prev=(int16_t)next_u32();s.curr=(int16_t)next_u32();s.fill=(uint16_t)next_u32();}
        int16_t y=ua_reference(s,target,gain);
        if(fprintf(f,"%d %d %u %d\n",s.prev,s.curr,s.fill,y)<0) return 2;
    }
    if(fclose(f)!=0)return 2;
    printf("generated %d vectors; scalar baseline %llu cycles\n",N,
           (unsigned long long)ua_baseline_cycles(N));
    return 0;
}
