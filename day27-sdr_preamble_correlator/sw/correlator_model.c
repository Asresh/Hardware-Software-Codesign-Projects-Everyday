/* Author: Asresh */
#include "correlator.h"

uint64_t corr_reference(const struct corr_complex8 sample[CORR_LANES],
                        const struct corr_complex8 tap[CORR_LANES]) {
    int32_t sum_i = 0;
    int32_t sum_q = 0;
    size_t lane;
    for (lane = 0; lane < CORR_LANES; ++lane) {
        const int32_t si = sample[lane].i;
        const int32_t sq = sample[lane].q;
        const int32_t ti = tap[lane].i;
        const int32_t tq = tap[lane].q;
        sum_i += si * ti + sq * tq;
        sum_q += sq * ti - si * tq;
    }
    return (uint64_t)((int64_t)sum_i * sum_i) +
           (uint64_t)((int64_t)sum_q * sum_q);
}
