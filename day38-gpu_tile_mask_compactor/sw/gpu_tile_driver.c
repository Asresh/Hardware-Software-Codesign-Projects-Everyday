/* Author: Asresh */
#include "gpu_tile_mask.h"
int gtm_configure(gtm_device *dev, unsigned sparse_threshold) {
    if (dev == NULL || dev->regs == NULL || sparse_threshold > 64u) return -1;
    dev->regs[GTM_CTRL] = 2u;
    dev->regs[GTM_THRESHOLD] = sparse_threshold;
    dev->regs[GTM_CTRL] = 1u;
    return 0;
}
void gtm_ack_irq(gtm_device *dev) {
    if (dev != NULL && dev->regs != NULL) dev->regs[GTM_CTRL] = 5u;
}
