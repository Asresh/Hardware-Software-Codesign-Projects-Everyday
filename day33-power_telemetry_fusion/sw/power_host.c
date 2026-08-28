/* Author: Asresh */
/* Deterministic host harness: builds directed and random samples, checks the
 * scalar path, exercises descriptor preparation plus MMIO completion handling,
 * and writes the C model's expected outputs for the RTL differential test. */
#include "power_telemetry.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SAMPLE_COUNT 320u

struct mock_device { uint32_t regs[32]; };

static uint32_t mock_read(void *context, uint32_t offset)
{
    struct mock_device *device = context;
    return device->regs[offset / 4u];
}

static void mock_write(void *context, uint32_t offset, uint32_t value)
{
    struct mock_device *device = context;
    if (offset == PTF_IRQ_STATUS)
        device->regs[offset / 4u] &= ~value;
    else
        device->regs[offset / 4u] = value;
    if (offset == PTF_CTRL && (value & PTF_CTRL_START) != 0u)
        device->regs[PTF_IRQ_STATUS / 4u] = PTF_IRQ_DONE;
}

static uint32_t next_random(uint32_t *state)
{
    uint32_t value = *state;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    *state = value;
    return value;
}

static uint32_t pack_sample(uint32_t voltage, uint32_t current, int32_t temperature)
{
    return (voltage & 0xfffu) | ((current & 0xfffu) << 12) |
           ((uint32_t)(uint8_t)temperature << 24);
}

int main(void)
{
    const struct ptf_config config = {900u, 85, 19u, 3u, 41u, 5900u};
    uint32_t samples[SAMPLE_COUNT];
    uint32_t expected[SAMPLE_COUNT];
    uint32_t baseline_results[SAMPLE_COUNT];
    struct mock_device mock = {{0u}};
    const struct ptf_io io = {&mock, mock_read, mock_write};
    struct ptf_descriptor descriptor;
    uint32_t random_state = 0x33c0de5u;
    uint64_t baseline_cycles;
    FILE *output;
    size_t index;

    samples[0] = pack_sample(900u, 0u, 25);
    samples[1] = pack_sample(0u, 4095u, 127);
    samples[2] = pack_sample(4095u, 4095u, -128);
    samples[3] = pack_sample(899u, 1u, 86);
    samples[4] = pack_sample(897u, 1934u, 86); /* risk exactly threshold */
    samples[5] = pack_sample(700u, 600u, 110);
    samples[6] = pack_sample(901u, 0u, 84);
    samples[7] = pack_sample(0u, 0u, -1);
    for (index = 8u; index < SAMPLE_COUNT; ++index) {
        uint32_t random_value = next_random(&random_state);
        uint32_t voltage = 650u + (random_value & 0x1ffu);
        uint32_t current = (random_value >> 9) & 0xfffu;
        int32_t temperature = (int32_t)((random_value >> 21) & 0x7fu) - 20;
        samples[index] = pack_sample(voltage, current, temperature);
    }
    for (index = 0u; index < SAMPLE_COUNT; ++index)
        expected[index] = ptf_reference(samples[index], &config);
    baseline_cycles = ptf_scalar_baseline(samples, baseline_results,
                                           SAMPLE_COUNT, &config);
    for (index = 0u; index < SAMPLE_COUNT; ++index) {
        if (expected[index] != baseline_results[index]) {
            fprintf(stderr, "reference mismatch at %zu\n", index);
            return EXIT_FAILURE;
        }
    }
    if (ptf_prepare_descriptor(&descriptor, 0x200u, 0x800u,
                               SAMPLE_COUNT) != 0 ||
        descriptor.src_addr != 0x200u || descriptor.dst_addr != 0x800u ||
        descriptor.count != SAMPLE_COUNT || descriptor.flags != 0u) {
        fputs("descriptor preparation test failed\n", stderr);
        return EXIT_FAILURE;
    }
    if (ptf_prepare_descriptor(&descriptor, 0x202u, 0x800u,
                               SAMPLE_COUNT) == 0) {
        fputs("invalid descriptor accepted\n", stderr);
        return EXIT_FAILURE;
    }
    if (ptf_run(&io, 0x100u, &config, 32u) != 0) {
        fputs("driver completion test failed\n", stderr);
        return EXIT_FAILURE;
    }
    output = fopen("tb/vectors.txt", "w");
    if (output == NULL) {
        fprintf(stderr, "cannot open tb/vectors.txt: %s\n", strerror(errno));
        return EXIT_FAILURE;
    }
    if (fprintf(output, "%u %u %d %u %u %u %u %llu\n", SAMPLE_COUNT,
                config.nominal_mv, config.temperature_limit_c,
                config.droop_weight, config.current_weight,
                config.thermal_weight, config.alert_threshold,
                (unsigned long long)baseline_cycles) < 0) {
        fclose(output);
        return EXIT_FAILURE;
    }
    for (index = 0u; index < SAMPLE_COUNT; ++index) {
        if (fprintf(output, "%08x %08x\n", samples[index], expected[index]) < 0) {
            fclose(output);
            return EXIT_FAILURE;
        }
    }
    if (fclose(output) != 0)
        return EXIT_FAILURE;
    printf("generated %u samples, scalar baseline %llu cycles\n", SAMPLE_COUNT,
           (unsigned long long)baseline_cycles);
    return EXIT_SUCCESS;
}
