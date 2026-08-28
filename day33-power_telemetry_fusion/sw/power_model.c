/* Author: Asresh */
/* Independent bit-exact model of the packed-sample arithmetic. It deliberately
 * uses widened unsigned products so C optimization cannot invoke signed-overflow
 * assumptions that differ between the macOS and Ubuntu toolchains. */
#include "power_telemetry.h"

uint32_t ptf_reference(uint32_t packed_sample, const struct ptf_config *config)
{
    uint32_t voltage = packed_sample & 0xfffu;
    uint32_t current = (packed_sample >> 12) & 0xfffu;
    int32_t temperature = (int32_t)(int8_t)(packed_sample >> 24);
    uint32_t droop;
    uint32_t hot;
    uint32_t risk;
    if (config == NULL)
        return 0u;
    droop = voltage < config->nominal_mv ?
                     (uint32_t)config->nominal_mv - voltage : 0u;
    hot = temperature > config->temperature_limit_c ?
                   (uint32_t)(temperature - config->temperature_limit_c) : 0u;
    risk = droop * config->droop_weight;
    risk += current * config->current_weight;
    risk += hot * config->thermal_weight;
    if (risk > 0x7fffffffu)
        risk = 0x7fffffffu;
    return risk | (risk >= config->alert_threshold ? 0x80000000u : 0u);
}
