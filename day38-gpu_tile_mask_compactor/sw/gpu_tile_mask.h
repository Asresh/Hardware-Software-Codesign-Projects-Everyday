/* Author: Asresh */
#ifndef GPU_TILE_MASK_H
#define GPU_TILE_MASK_H
#include <stddef.h>
#include <stdint.h>
enum { GTM_CTRL=0, GTM_STATUS=1, GTM_IN_COUNT=2, GTM_OUT_COUNT=3,
       GTM_BATCH_COUNT=4, GTM_ZERO_COUNT=5, GTM_THRESHOLD=6 };
typedef struct { volatile uint32_t *regs; } gtm_device;
typedef struct { uint8_t count, first, last, empty, sparse; } gtm_result;
int gtm_configure(gtm_device *dev, unsigned sparse_threshold);
void gtm_ack_irq(gtm_device *dev);
gtm_result gtm_reference(uint64_t mask, unsigned sparse_threshold);
uint32_t gtm_pack(gtm_result result);
#endif
