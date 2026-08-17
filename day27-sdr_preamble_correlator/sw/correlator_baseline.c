/* Author: Asresh */
#include "correlator.h"

uint64_t corr_baseline_cycles(size_t vectors) {
    /* Per vector: 32 multiplies/adds, 14 reductions, two squares and compare. */
    return (uint64_t)vectors * 49u;
}
