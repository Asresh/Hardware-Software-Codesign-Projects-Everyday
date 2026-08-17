/* Author: Asresh */
#include "correlator.h"

void corr_configure(struct corr_device *dev,
                    const struct corr_complex8 taps[CORR_LANES],
                    uint64_t threshold) {
    size_t lane;
    dev->write32(dev->ctx, CORR_CTRL, CORR_CTRL_CLEAR);
    dev->write32(dev->ctx, CORR_THRESH_LO, (uint32_t)threshold);
    dev->write32(dev->ctx, CORR_THRESH_HI, (uint32_t)(threshold >> 32));
    for (lane = 0; lane < CORR_LANES; ++lane) {
        const uint32_t packed = (uint8_t)taps[lane].i |
                                ((uint32_t)(uint8_t)taps[lane].q << 8);
        dev->write32(dev->ctx, CORR_TAP_BASE + (uint32_t)(lane * 4u), packed);
    }
    dev->write32(dev->ctx, CORR_CTRL, CORR_CTRL_ENABLE | CORR_CTRL_IRQ_EN);
}

int corr_submit(struct corr_device *dev, const struct corr_vector *vectors,
                size_t count, unsigned poll_limit) {
    unsigned poll;
    if (count == 0u || dev->stream(dev->ctx, vectors, count) != 0)
        return -1;
    for (poll = 0; poll < poll_limit; ++poll)
        if ((dev->read32(dev->ctx, CORR_STATUS) & 2u) != 0u)
            return 0;
    return -2;
}

void corr_handle_irq(struct corr_device *dev) {
    dev->write32(dev->ctx, CORR_IRQ_ACK, 1u);
}
