/* Author: Asresh. Shared SECDED model, descriptor, and driver contract. */
#ifndef DDR_RAS_H
#define DDR_RAS_H
#include <stdint.h>
typedef struct { uint32_t base; uint32_t count; } ras_desc_t;
typedef struct { uint32_t corrected; uint32_t uncorrectable; } ras_stats_t;
uint64_t ras_encode(uint32_t data); uint64_t ras_check(uint64_t code,unsigned *corrected,unsigned *uncorrectable);
uint64_t ras_baseline_cycles(uint32_t words); int ras_submit(volatile uint32_t *mmio,const ras_desc_t *desc,ras_stats_t *stats);
#endif
