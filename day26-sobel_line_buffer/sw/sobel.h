/* Author: Asresh */
#ifndef SOBEL_H
#define SOBEL_H
#include <stddef.h>
#include <stdint.h>
enum { SOBEL_CTRL=0x00, SOBEL_WIDTH=0x04, SOBEL_HEIGHT=0x08, SOBEL_STATUS=0x0c,
       SOBEL_PIXELS_IN=0x10, SOBEL_PIXELS_OUT=0x14, SOBEL_IRQ_STATUS=0x18, SOBEL_CAPS=0x1c };
typedef uint32_t (*sobel_read32_fn)(void *, uint32_t);
typedef void (*sobel_write32_fn)(void *, uint32_t, uint32_t);
typedef int (*sobel_stream_tx_fn)(void *, uint8_t);
typedef int (*sobel_stream_rx_fn)(void *, uint8_t *);
struct sobel_device { void *ctx; sobel_read32_fn read32; sobel_write32_fn write32; sobel_stream_tx_fn tx; sobel_stream_rx_fn rx; };
int sobel_configure(struct sobel_device *d,uint16_t width,uint16_t height);
int sobel_run(struct sobel_device *d,const uint8_t *src,uint8_t *dst,size_t timeout);
void sobel_isr(struct sobel_device *d);
uint8_t sobel_reference_pixel(const uint8_t *p,size_t stride);
uint64_t sobel_baseline_cycles(uint16_t width,uint16_t height);
#endif
