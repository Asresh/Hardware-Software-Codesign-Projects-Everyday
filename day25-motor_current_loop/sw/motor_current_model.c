// Author: Asresh
// Independent fixed-width reference for the bit-serial hardware contract.
#include "motor_current.h"
#include <stdint.h>

struct mc_result mc_reference(int16_t reference, int16_t measured,
                              uint8_t gain_q8, uint16_t trip, int external_fault) {
    const int32_t error = (int32_t)reference - (int32_t)measured;
    const int64_t product = (int64_t)error * (int64_t)gain_q8;
    const int64_t scaled = product >= 0 ? product / 256 : -((-product + 255) / 256);
    const int32_t measured32 = measured;
    const uint32_t magnitude = measured32 < 0 ? (uint32_t)(-measured32) : (uint32_t)measured32;
    struct mc_result out = {0u, 0u};
    if (external_fault || magnitude > trip) {
        out.flags = MC_FLAG_FAULT;
    } else if (scaled + 32768 > 65535) {
        out.duty = 65535u;
        out.flags = MC_FLAG_SAT_HI;
    } else if (scaled + 32768 < 0) {
        out.duty = 0u;
        out.flags = MC_FLAG_SAT_LO;
    } else {
        out.duty = (uint16_t)(scaled + 32768);
    }
    return out;
}
