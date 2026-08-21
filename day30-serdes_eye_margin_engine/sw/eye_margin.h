/* Author: Asresh */
#ifndef EYE_MARGIN_H
#define EYE_MARGIN_H
#include <stddef.h>
#include <stdint.h>
#define EYE_MAX_POINTS 128u
struct eye_point { uint8_t phase; uint16_t errors; uint8_t last; };
struct eye_result { uint8_t best_start; uint16_t best_length; uint16_t sample_count; };
struct eye_regs { volatile uint32_t control, status, error_limit, best_start, best_length, sample_count, fifo_level, irq_status, device_id; };
typedef int (*eye_push_fn)(void *, const struct eye_point *);
int eye_reference(const struct eye_point *points, size_t count, uint16_t limit, struct eye_result *out);
uint64_t eye_scalar_cycles(size_t count);
int eye_run(struct eye_regs *regs, eye_push_fn push, void *context,
            const struct eye_point *points, size_t count, uint16_t limit,
            uint32_t timeout, struct eye_result *out);
#endif
