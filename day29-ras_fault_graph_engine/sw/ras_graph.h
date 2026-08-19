/* Author: Asresh */
#ifndef RAS_GRAPH_H
#define RAS_GRAPH_H
#include <stdint.h>
#include <stddef.h>
#define RAS_NODES 16u
struct ras_case { uint16_t row[RAS_NODES]; uint16_t seed; uint16_t reached; uint32_t iterations; };
uint16_t ras_reference(const uint16_t row[RAS_NODES], uint16_t seed, uint32_t *iterations);
uint64_t ras_scalar_baseline(const uint16_t row[RAS_NODES], uint16_t seed, uint16_t *reached);
struct ras_mmio { volatile uint32_t *base; };
int ras_run(struct ras_mmio *dev,const uint16_t row[RAS_NODES],uint16_t seed,uint16_t *reached,uint32_t timeout);
#endif
