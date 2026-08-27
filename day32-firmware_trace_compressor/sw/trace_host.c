/* Author: Asresh */
#include "trace_compressor.h"
#include <inttypes.h>
#include <stdio.h>

typedef struct {
    trace_record_t input[TRACE_RING_DEPTH];
    trace_packet_t output[TRACE_RING_DEPTH];
    size_t count, produced;
    uint32_t status;
} mock_device_t;

static uint32_t rng_state = 0x32a5c0deu;
static uint32_t next_random(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

static void mock_write(void *opaque, uint32_t addr, uint32_t value)
{
    mock_device_t *mock = opaque;
    if (addr >= TRACE_INPUT_WINDOW && addr < TRACE_INPUT_WINDOW + TRACE_RING_DEPTH * 4u) {
        mock->input[(addr - TRACE_INPUT_WINDOW) / 4u] = value;
    } else if (addr == TRACE_REG_INPUT_COUNT) {
        mock->count = value;
    } else if (addr == TRACE_REG_CTRL && (value & 1u) != 0u) {
        mock->produced = trace_reference(mock->input, mock->count, mock->output,
                                         TRACE_RING_DEPTH);
        mock->status = mock->produced == 0u ? 8u : 4u;
    } else if (addr == TRACE_REG_CTRL && (value & 4u) != 0u) {
        mock->status = 0u;
    }
}

static uint32_t mock_read(void *opaque, uint32_t addr)
{
    mock_device_t *mock = opaque;
    if (addr == TRACE_REG_STATUS) return mock->status;
    if (addr == TRACE_REG_OUTPUT_COUNT) return (uint32_t)mock->produced;
    if (addr >= TRACE_OUTPUT_WINDOW && addr < TRACE_OUTPUT_WINDOW + TRACE_RING_DEPTH * 8u) {
        const size_t index = (addr - TRACE_OUTPUT_WINDOW) / 8u;
        const unsigned high = (addr & 4u) != 0u;
        return high ? (uint32_t)(mock->output[index] >> 32) : (uint32_t)mock->output[index];
    }
    return 0u;
}

int main(void)
{
    trace_record_t input[TRACE_RING_DEPTH];
    trace_packet_t expected[TRACE_RING_DEPTH], driven[TRACE_RING_DEPTH];
    mock_device_t mock = {{0}, {0}, 0u, 0u, 0u};
    trace_device_t device = {&mock, mock_write, mock_read};
    size_t i, expected_count, driven_count = 0u;
    uint16_t timestamp = 0u;
    uint8_t event = 0u, payload = 0u;
    FILE *file;

    for (i = 0u; i < 320u; ++i) {
        if (i == 0u) { timestamp = 0u; event = 0u; payload = 0u; }
        else if (i == 1u) timestamp = UINT16_MAX;
        else {
            timestamp = (uint16_t)(timestamp + (uint16_t)(next_random() & 31u));
            if ((next_random() & 7u) < 2u) {
                event = (uint8_t)next_random();
                payload = (uint8_t)(next_random() >> 8);
            }
        }
        input[i] = ((uint32_t)timestamp << 16) | ((uint32_t)event << 8) | payload;
    }
    input[2] = 0xffffffffu;
    input[3] = 0xffffffffu;
    input[4] = 0xffff0000u;
    expected_count = trace_reference(input, 320u, expected, TRACE_RING_DEPTH);
    if (expected_count == 0u || trace_driver_run(&device, input, 320u,
        driven, TRACE_RING_DEPTH, &driven_count, 1000u) != 0 || driven_count != expected_count)
        return 1;
    for (i = 0u; i < expected_count; ++i)
        if (driven[i] != expected[i]) return 1;

    file = fopen("tb/vectors.txt", "w");
    if (file == NULL) return 1;
    if (fprintf(file, "# Author: Asresh\nMETA %u %zu %" PRIu64 "\n",
                320u, expected_count,
                trace_scalar_cycles(input, 320u)) < 0) {
        (void)fclose(file); return 1;
    }
    for (i = 0u; i < 320u; ++i)
        if (fprintf(file, "IN %08" PRIx32 "\n", input[i]) < 0) {
            (void)fclose(file); return 1;
        }
    for (i = 0u; i < expected_count; ++i)
        if (fprintf(file, "OUT %016" PRIx64 "\n", expected[i]) < 0) {
            (void)fclose(file); return 1;
        }
    if (fclose(file) != 0) return 1;
    printf("generated 320 trace records and %zu packets\n", expected_count);
    return 0;
}
