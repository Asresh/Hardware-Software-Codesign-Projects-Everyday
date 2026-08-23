/* Author: Asresh */
#ifndef TRACE_COMPRESSOR_H
#define TRACE_COMPRESSOR_H
#include <stddef.h>
#include <stdint.h>

#define TRACE_RING_DEPTH 512u
#define TRACE_REG_CTRL 0x000u
#define TRACE_REG_STATUS 0x004u
#define TRACE_REG_INPUT_COUNT 0x008u
#define TRACE_REG_OUTPUT_COUNT 0x00cu
#define TRACE_INPUT_WINDOW 0x100u
#define TRACE_OUTPUT_WINDOW 0x1000u

typedef uint32_t trace_record_t;
typedef uint64_t trace_packet_t;
typedef void (*trace_write_fn)(void *, uint32_t, uint32_t);
typedef uint32_t (*trace_read_fn)(void *, uint32_t);

typedef struct {
    void *context;
    trace_write_fn write32;
    trace_read_fn read32;
} trace_device_t;

size_t trace_reference(const trace_record_t *input, size_t count,
                       trace_packet_t *output, size_t capacity);
uint64_t trace_scalar_cycles(const trace_record_t *input, size_t count);
int trace_driver_run(trace_device_t *device, const trace_record_t *input,
                     size_t count, trace_packet_t *output, size_t capacity,
                     size_t *output_count, uint32_t timeout);
#endif
