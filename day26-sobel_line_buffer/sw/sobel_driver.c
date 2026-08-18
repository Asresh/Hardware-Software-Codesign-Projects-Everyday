/* Author: Asresh */
/* Portable driver: validates geometry, programs MMIO, streams a frame, waits for IRQ state, and acknowledges W1C. */
#include "sobel.h"
int sobel_configure(struct sobel_device *d,uint16_t width,uint16_t height){
 if(!d||!d->read32||!d->write32||!d->tx||!d->rx||width<3||width>64||height<3)return -1;
 d->write32(d->ctx,SOBEL_WIDTH,width);d->write32(d->ctx,SOBEL_HEIGHT,height);d->write32(d->ctx,SOBEL_CTRL,2u);return 0;
}
int sobel_run(struct sobel_device *d,const uint8_t *src,uint8_t *dst,size_t timeout){
 uint32_t w=d->read32(d->ctx,SOBEL_WIDTH)&0xffffu,h=d->read32(d->ctx,SOBEL_HEIGHT)&0xffffu;
 size_t ni=(size_t)w*h,no=(size_t)(w-2u)*(h-2u),i=0,o=0,spins=0;d->write32(d->ctx,SOBEL_CTRL,0x102u);
 while((i<ni||o<no)&&spins++<timeout){if(i<ni&&d->tx(d->ctx,src[i])==0)i++;if(o<no&&d->rx(d->ctx,&dst[o])==0)o++;}
 if(i!=ni||o!=no)return -2;
 while(!(d->read32(d->ctx,SOBEL_IRQ_STATUS)&1u)&&spins++<timeout){}
 return spins>=timeout?-3:0;
}
void sobel_isr(struct sobel_device *d){d->write32(d->ctx,SOBEL_IRQ_STATUS,1u);}
