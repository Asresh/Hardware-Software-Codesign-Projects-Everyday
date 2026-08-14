/* Author: Asresh. Bare-metal descriptor launch, completion, and telemetry driver. */
#include "ddr_ras.h"
enum{R_CTRL=0,R_BASE=1,R_COUNT=2,R_STATUS=3,R_CORR=4,R_BAD=5,R_IRQ=6};
int ras_submit(volatile uint32_t*r,const ras_desc_t*d,ras_stats_t*s){uint32_t timeout=1000000u;r[R_BASE]=d->base;r[R_COUNT]=d->count;r[R_CTRL]=1u;while(!(r[R_STATUS]&2u)&&--timeout){}if(!timeout)return-1;s->corrected=r[R_CORR];s->uncorrectable=r[R_BAD];r[R_IRQ]=1u;return 0;}
