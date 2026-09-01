/* Author: Asresh */
#include "minimizer.h"
#include <limits.h>
static uint32_t reverse_complement(uint32_t x, unsigned bases) {
    uint32_t r=0; unsigned i;
    for (i=0;i<bases;i++) r |= ((~(x >> (2u*i))) & 3u) << (2u*(bases-1u-i));
    return r;
}
uint32_t minimizer_hash(uint32_t packed_kmer, uint32_t seed, unsigned bases) {
    uint32_t r=reverse_complement(packed_kmer,bases), x=(packed_kmer<r?packed_kmer:r)^seed;
    x ^= x >> 16; x *= UINT32_C(0x7feb352d); x ^= x >> 15; return x;
}
size_t minimizer_reference(const uint32_t *kmers, size_t n, unsigned bases, unsigned window, uint32_t seed, minimizer_result *out) {
    size_t i,j,o=0;
    for(i=0;i<n;i++) if(i+1>=window) {
        uint32_t best=UINT32_MAX, pos=0;
        for(j=i+1-window;j<=i;j++) { uint32_t h=minimizer_hash(kmers[j],seed,bases); if(h<best) {best=h;pos=(uint32_t)j;} }
        out[o].hash=best; out[o].position=pos; o++;
    }
    return o;
}
