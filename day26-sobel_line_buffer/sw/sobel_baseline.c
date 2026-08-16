/* Author: Asresh */
/* Scalar embedded-CPU cycle model: load/store and exact arithmetic costs for the same 3x3 calculation. */
#include "sobel.h"
uint64_t sobel_baseline_cycles(uint16_t w,uint16_t h){
 uint64_t in=(uint64_t)w*h,out=(uint64_t)(w-2u)*(h-2u);
 return 12u+in*3u+out*29u; /* setup + input reads + 8 loads, six adds, shifts, abs, clamp, store */
}
