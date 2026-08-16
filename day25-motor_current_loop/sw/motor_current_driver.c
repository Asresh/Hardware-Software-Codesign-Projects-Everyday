// Author: Asresh
// Portable bare-metal mailbox driver: configure, submit, poll/IRQ, read result, acknowledge.
#include "motor_current.h"
#include <stdint.h>

static void wr(struct mc_device *d, uint32_t off, uint32_t value) { d->base[off / 4u] = value; }
static uint32_t rd(struct mc_device *d, uint32_t off) { return d->base[off / 4u]; }

void mc_configure(struct mc_device *dev, uint8_t gain_q8, uint16_t trip) {
    wr(dev, MC_GAIN_Q8, gain_q8);
    wr(dev, MC_TRIP, trip);
    wr(dev, MC_CTRL, 3u);
}

int mc_submit(struct mc_device *dev, int16_t reference, int16_t measured,
              int external_fault, uint32_t timeout, struct mc_result *result) {
    wr(dev, MC_REFERENCE, (uint16_t)reference);
    wr(dev, MC_MEASURED, (uint16_t)measured);
    wr(dev, MC_DOORBELL, 1u | (external_fault ? 2u : 0u));
    while (timeout-- != 0u) {
        const uint32_t status = rd(dev, MC_STATUS);
        if ((status & (1u << 2)) != 0u) {
            result->duty = (uint16_t)rd(dev, MC_DUTY);
            result->flags = (uint8_t)((status >> 3) & 7u);
            mc_isr(dev);
            return 0;
        }
    }
    return -1;
}

void mc_isr(struct mc_device *dev) { wr(dev, MC_IRQ_STATUS, 1u); }
