/* Author: Asresh */
#include "kinematics.h"
#include <stdio.h>
#include <stdlib.h>
static uint32_t rng_state=UINT32_C(0x31c0de57);
static uint32_t next_random(void) { rng_state=rng_state*UINT32_C(1664525)+UINT32_C(1013904223); return rng_state; }
static int emit_job(FILE *fp, unsigned index, const struct kin_joint *joints, size_t count, uint64_t *baseline_total) {
    struct kin_result expected, scalar; size_t i; uint64_t baseline;
    if (kin_reference(joints,count,&expected)!=0 || kin_scalar_reference(joints,count,&scalar)!=0) return -1;
    baseline=kin_scalar_cycles(count); *baseline_total += baseline;
    if (fprintf(fp,"%u %zu %d %d %llu\n",index,count,expected.x_q8,expected.y_q8,(unsigned long long)baseline)<0) return -1;
    for (i=0;i<count;++i) if (fprintf(fp,"%u %d\n",joints[i].length_q8,joints[i].angle_q13)<0) return -1;
    return 0;
}
int main(int argc,char **argv) {
    char path[512]; FILE *fp; struct kin_joint joints[KIN_MAX_JOINTS]; uint64_t total=0; unsigned job; int n,rc=0;
    static const int16_t corner_angles[16]={0,12868,-12868,25736,-25736,6434,-6434,1,-1,20000,-20000,8579,-8579,17157,-17157,3000};
    if (argc!=2) { (void)fprintf(stderr,"usage: %s OUTPUT_DIR\n",argv[0]); return 2; }
    n=snprintf(path,sizeof(path),"%s/vectors.txt",argv[1]);
    if (n<0 || (size_t)n>=sizeof(path)) { (void)fprintf(stderr,"output path too long\n"); return 2; }
    fp=fopen(path,"w"); if (fp==NULL) { perror(path); return 2; }
    if (fprintf(fp,"# Author: Asresh\n320\n")<0) rc=1;
    for (job=0;job<320u && rc==0;++job) {
        size_t count=(job<16u)?(size_t)(1u+(job%KIN_MAX_JOINTS)):(size_t)(1u+next_random()%KIN_MAX_JOINTS); size_t i;
        for (i=0;i<count;++i) {
            if (job<16u) { joints[i].length_q8=(uint16_t)((job==0u)?0u:((job==15u)?65535u:(256u*(i+1u)))); joints[i].angle_q13=corner_angles[(job+i)%16u]; }
            else { joints[i].length_q8=(uint16_t)(next_random()&UINT32_C(0xffff)); joints[i].angle_q13=(int16_t)((int32_t)(next_random()%UINT32_C(51473))-KIN_PI_Q13); }
        }
        if (emit_job(fp,job,joints,count,&total)!=0) rc=1;
    }
    if (fclose(fp)!=0) rc=1;
    if (rc!=0) { (void)fprintf(stderr,"vector generation failed\n"); return 1; }
    (void)printf("generated 320 kinematic chains; scalar baseline cycles=%llu\n",(unsigned long long)total);
    return 0;
}
