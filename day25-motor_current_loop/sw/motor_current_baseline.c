// Author: Asresh
// Cycle-accounted scalar MCU baseline: ADC read, safety branch, multiply/divide, clamp, PWM write.
#include "motor_current.h"
#include <stdint.h>

uint32_t mc_baseline_cycles(int16_t reference, int16_t measured,
                            uint8_t gain_q8, uint16_t trip, int external_fault) {
    uint32_t cycles = 46u; /* loads, sign extension, error and branch setup */
    int32_t magnitude = measured;
    if (magnitude < 0) magnitude = -magnitude;
    cycles += external_fault || (uint32_t)magnitude > trip ? 10u : 38u;
    cycles += gain_q8 == 0u ? 3u : 12u; /* library multiply and Q8 scaling */
    cycles += reference == measured ? 2u : 5u;
    return cycles;
}
