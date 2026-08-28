/* Author: Asresh */
/* Portable firmware driver. It constructs the shared-memory DMA contract,
 * programs fusion policy, launches the engine, polls with a hard bound, and
 * acknowledges the sticky completion interrupt. */
#include "power_telemetry.h"

int ptf_prepare_descriptor(struct ptf_descriptor *descriptor,
                           uint32_t source_addr, uint32_t destination_addr,
                           size_t count)
{
    if (descriptor == NULL || count == 0u || count > 1024u ||
        (source_addr & 3u) != 0u || (destination_addr & 3u) != 0u)
        return -1;
    descriptor->src_addr = source_addr;
    descriptor->dst_addr = destination_addr;
    descriptor->count = (uint32_t)count;
    descriptor->flags = 0u;
    return 0;
}

int ptf_run(const struct ptf_io *io, uint32_t descriptor_addr,
            const struct ptf_config *config, uint32_t timeout)
{
    uint32_t weights;
    uint32_t polls;
    if (io == NULL || io->read32 == NULL || io->write32 == NULL ||
        config == NULL || timeout == 0u || (descriptor_addr & 3u) != 0u ||
        config->nominal_mv > 4095u || config->alert_threshold > 0x7fffffffu)
        return -1;
    weights = (uint32_t)config->droop_weight |
              ((uint32_t)config->current_weight << 8) |
              ((uint32_t)config->thermal_weight << 16);
    io->write32(io->context, PTF_VNOM, config->nominal_mv);
    io->write32(io->context, PTF_TLIMIT,
                (uint32_t)(uint8_t)config->temperature_limit_c);
    io->write32(io->context, PTF_WEIGHTS, weights);
    io->write32(io->context, PTF_THRESHOLD, config->alert_threshold);
    io->write32(io->context, PTF_DESC_ADDR, descriptor_addr);
    io->write32(io->context, PTF_IRQ_STATUS, PTF_IRQ_DONE);
    io->write32(io->context, PTF_CTRL, PTF_CTRL_START | PTF_CTRL_IRQ_EN);
    for (polls = 0; polls < timeout; ++polls) {
        if ((io->read32(io->context, PTF_IRQ_STATUS) & PTF_IRQ_DONE) != 0u) {
            io->write32(io->context, PTF_IRQ_STATUS, PTF_IRQ_DONE);
            return 0;
        }
    }
    return -2;
}
