/* Author: Asresh */
#include "eye_margin.h"
uint64_t eye_scalar_cycles(size_t count) {
    /* load phase/errors, compare, branch, run update and best update */
    return 18u + (uint64_t)count * 11u;
}
