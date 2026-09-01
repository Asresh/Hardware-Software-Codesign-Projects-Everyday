/* Author: Asresh */
#ifndef MINIMIZER_H
#define MINIMIZER_H
#include <stdint.h>
#include <stddef.h>
enum { MIN_CTRL=0, MIN_SEED=1, MIN_STATUS=2, MIN_IRQ=3, MIN_ACCEPTED=4, MIN_EMITTED=5 };
typedef struct { volatile uint32_t *regs; } minimizer_dev;
typedef struct { uint32_t hash, position; } minimizer_result;
void minimizer_configure(minimizer_dev *dev, uint32_t seed);
uint32_t minimizer_hash(uint32_t packed_kmer, uint32_t seed, unsigned bases);
size_t minimizer_reference(const uint32_t *kmers, size_t n, unsigned bases, unsigned window, uint32_t seed, minimizer_result *out);
#endif
