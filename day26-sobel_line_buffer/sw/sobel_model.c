/* Author: Asresh */
/* Independent fixed-width Sobel reference; p points at the top-left sample of a 3x3 window. */
#include "sobel.h"
static int iabs_safe(int x){return x<0?-x:x;}
uint8_t sobel_reference_pixel(const uint8_t *p,size_t s){
 int gx=(int)p[2]+2*(int)p[s+2]+(int)p[2*s+2]-(int)p[0]-2*(int)p[s]-(int)p[2*s];
 int gy=(int)p[0]+2*(int)p[1]+(int)p[2]-(int)p[2*s]-2*(int)p[2*s+1]-(int)p[2*s+2];
 int mag=iabs_safe(gx)+iabs_safe(gy);return (uint8_t)(mag>255?255:mag);
}
