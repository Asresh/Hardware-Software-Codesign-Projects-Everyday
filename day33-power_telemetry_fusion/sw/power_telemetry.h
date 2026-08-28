/* Author: Asresh */
/* Public firmware contract: register offsets, descriptor/configuration layouts,
 * portable MMIO callbacks, driver entry points, and reference/baseline APIs. */
#ifndef POWER_TELEMETRY_H
#define POWER_TELEMETRY_H

#include <stddef.h>
#include <stdint.h>

enum {
    PTF_CTRL = 0x00u, PTF_STATUS = 0x04u, PTF_DESC_ADDR = 0x08u,
    PTF_CYCLES = 0x0cu, PTF_SAMPLES = 0x10u, PTF_VNOM = 0x14u,
    PTF_TLIMIT = 0x18u, PTF_WEIGHTS = 0x1cu, PTF_THRESHOLD = 0x20u,
    PTF_IRQ_STATUS = 0x24u, PTF_VERSION = 0x28u
};

enum { PTF_CTRL_START = 1u, PTF_CTRL_IRQ_EN = 2u, PTF_IRQ_DONE = 1u };

struct ptf_descriptor {
    uint32_t src_addr;
    uint32_t dst_addr;
    uint32_t count;
    uint32_t flags;
};

struct ptf_config {
    uint16_t nominal_mv;
    int8_t temperature_limit_c;
    uint8_t droop_weight;
    uint8_t current_weight;
    uint8_t thermal_weight;
    uint32_t alert_threshold;
};

struct ptf_io {
    void *context;
    uint32_t (*read32)(void *context, uint32_t offset);
    void (*write32)(void *context, uint32_t offset, uint32_t value);
};

uint32_t ptf_reference(uint32_t packed_sample, const struct ptf_config *config);
uint64_t ptf_scalar_baseline(const uint32_t *samples, uint32_t *results,
                             size_t count, const struct ptf_config *config);
int ptf_run(const struct ptf_io *io, uint32_t descriptor_addr,
            const struct ptf_config *config, uint32_t timeout);
int ptf_prepare_descriptor(struct ptf_descriptor *descriptor,
                           uint32_t source_addr, uint32_t destination_addr,
                           size_t count);

#endif
