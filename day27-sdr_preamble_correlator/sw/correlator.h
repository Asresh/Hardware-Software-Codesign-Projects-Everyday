/* Author: Asresh */
#ifndef CORRELATOR_H
#define CORRELATOR_H
#include <stddef.h>
#include <stdint.h>

#define CORR_LANES 8u
#define CORR_CTRL 0x00u
#define CORR_STATUS 0x04u
#define CORR_THRESH_LO 0x08u
#define CORR_THRESH_HI 0x0cu
#define CORR_VECTORS 0x10u
#define CORR_DETECTIONS 0x14u
#define CORR_CAPS 0x18u
#define CORR_IRQ_ACK 0x1cu
#define CORR_TAP_BASE 0x40u
#define CORR_CTRL_ENABLE 0x1u
#define CORR_CTRL_CLEAR 0x2u
#define CORR_CTRL_IRQ_EN 0x4u

struct corr_complex8 { int8_t i, q; };
struct corr_vector {
    struct corr_complex8 sample[CORR_LANES];
    uint16_t tag;
    uint8_t last;
};
struct corr_result { uint64_t power; uint16_t tag; uint8_t detected; };

uint64_t corr_reference(const struct corr_complex8 sample[CORR_LANES],
                        const struct corr_complex8 tap[CORR_LANES]);
uint64_t corr_baseline_cycles(size_t vectors);

typedef void (*corr_write32_fn)(void *ctx, uint32_t addr, uint32_t value);
typedef uint32_t (*corr_read32_fn)(void *ctx, uint32_t addr);
typedef int (*corr_stream_fn)(void *ctx, const struct corr_vector *vectors,
                              size_t count);
struct corr_device {
    void *ctx;
    corr_write32_fn write32;
    corr_read32_fn read32;
    corr_stream_fn stream;
};
void corr_configure(struct corr_device *dev,
                    const struct corr_complex8 taps[CORR_LANES],
                    uint64_t threshold);
int corr_submit(struct corr_device *dev, const struct corr_vector *vectors,
                size_t count, unsigned poll_limit);
void corr_handle_irq(struct corr_device *dev);
#endif
