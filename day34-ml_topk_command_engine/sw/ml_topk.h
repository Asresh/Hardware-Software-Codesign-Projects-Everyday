/* Author: Asresh */
#ifndef ML_TOPK_H
#define ML_TOPK_H
#include <stddef.h>
#include <stdint.h>
#define TOPK_LANES 8u
#define TOPK_REG_CONTROL 0x00u
#define TOPK_REG_STATUS  0x04u
#define TOPK_REG_SOURCE  0x08u
#define TOPK_REG_DEST    0x0cu
#define TOPK_REG_COUNT   0x10u
#define TOPK_REG_CYCLES  0x14u
#define TOPK_REG_IRQ     0x18u
#define TOPK_CONTROL_START 1u
#define TOPK_CONTROL_IRQ_ENABLE 2u
#define TOPK_STATUS_BUSY 1u
#define TOPK_STATUS_IRQ 2u
#define TOPK_STATUS_ERROR 4u
struct topk_entry { int16_t value; uint8_t index; uint8_t reserved; };
struct topk_result { struct topk_entry top[2]; };
struct topk_io {
    void *context;
    void (*write32)(void *, uint32_t, uint32_t);
    uint32_t (*read32)(void *, uint32_t);
    int (*copy_to_device)(void *, uint32_t, const void *, size_t);
    int (*copy_from_device)(void *, void *, uint32_t, size_t);
};
void topk_reference(const int16_t scores[TOPK_LANES], struct topk_result *out);
uint32_t topk_baseline(const int16_t scores[TOPK_LANES], struct topk_result *out);
int topk_run(const struct topk_io *io,uint32_t source,uint32_t destination,
             const int16_t *scores,struct topk_result *results,size_t count,uint32_t timeout);
#endif
