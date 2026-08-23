/* Author: Asresh */
#include "trace_compressor.h"

static trace_packet_t pack(uint16_t first, uint16_t last, uint8_t event,
                           uint8_t payload, uint16_t run)
{
    return ((uint64_t)first << 48) | ((uint64_t)last << 32) |
           ((uint64_t)event << 24) | ((uint64_t)payload << 16) | run;
}

size_t trace_reference(const trace_record_t *input, size_t count,
                       trace_packet_t *output, size_t capacity)
{
    size_t used = 0u;
    size_t i;
    uint16_t first, last, run;
    uint8_t event, payload;
    if (input == NULL || output == NULL || count == 0u || capacity == 0u)
        return 0u;
    first = (uint16_t)(input[0] >> 16);
    last = first;
    event = (uint8_t)(input[0] >> 8);
    payload = (uint8_t)input[0];
    run = 1u;
    for (i = 1u; i < count; ++i) {
        const uint16_t ts = (uint16_t)(input[i] >> 16);
        const uint8_t next_event = (uint8_t)(input[i] >> 8);
        const uint8_t next_payload = (uint8_t)input[i];
        if (next_event == event && next_payload == payload && run != UINT16_MAX) {
            last = ts;
            ++run;
        } else {
            if (used >= capacity) return 0u;
            output[used++] = pack(first, last, event, payload, run);
            first = ts;
            last = ts;
            event = next_event;
            payload = next_payload;
            run = 1u;
        }
    }
    if (used >= capacity) return 0u;
    output[used++] = pack(first, last, event, payload, run);
    return used;
}
