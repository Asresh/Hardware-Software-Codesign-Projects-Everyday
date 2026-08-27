/* Author: Asresh */
#include "trace_compressor.h"

int trace_driver_run(trace_device_t *device, const trace_record_t *input,
                     size_t count, trace_packet_t *output, size_t capacity,
                     size_t *output_count, uint32_t timeout)
{
    size_t i, produced;
    uint32_t status;
    if (device == NULL || device->write32 == NULL || device->read32 == NULL ||
        input == NULL || output == NULL || output_count == NULL ||
        count == 0u || count > TRACE_RING_DEPTH || capacity < count || timeout == 0u)
        return -1;
    for (i = 0u; i < count; ++i)
        device->write32(device->context, TRACE_INPUT_WINDOW + (uint32_t)(i * 4u), input[i]);
    device->write32(device->context, TRACE_REG_INPUT_COUNT, (uint32_t)count);
    device->write32(device->context, TRACE_REG_CTRL, 3u);
    do {
        status = device->read32(device->context, TRACE_REG_STATUS);
        if ((status & 8u) != 0u) return -2;
        --timeout;
    } while ((status & 4u) == 0u && timeout != 0u);
    if ((status & 4u) == 0u) return -3;
    produced = device->read32(device->context, TRACE_REG_OUTPUT_COUNT);
    if (produced > capacity || produced > TRACE_RING_DEPTH) return -4;
    for (i = 0u; i < produced; ++i) {
        const uint32_t lo = device->read32(device->context,
                                           TRACE_OUTPUT_WINDOW + (uint32_t)(i * 8u));
        const uint32_t hi = device->read32(device->context,
                                           TRACE_OUTPUT_WINDOW + (uint32_t)(i * 8u + 4u));
        output[i] = ((uint64_t)hi << 32) | lo;
    }
    device->write32(device->context, TRACE_REG_CTRL, 6u);
    *output_count = produced;
    return 0;
}
