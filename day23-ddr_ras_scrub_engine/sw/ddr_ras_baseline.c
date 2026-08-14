/* Author: Asresh. Scalar in-order CPU instruction-cost baseline. */
#include "ddr_ras.h"
uint64_t ras_baseline_cycles(uint32_t words){return(uint64_t)words*92u+18u;}
