/* Author: Asresh */
#include "pcie_reorder.h"
int pcr_configure(pcr_device *dev, uint32_t target_count) {
    if (dev == NULL || dev->regs == NULL || target_count == 0u) return -1;
    dev->regs[PCR_TARGET] = target_count;
    dev->regs[PCR_CTRL] = 3u;
    dev->regs[PCR_CTRL] = 1u;
    return 0;
}
void pcr_ack_irq(pcr_device *dev) {
    if (dev != NULL && dev->regs != NULL) dev->regs[PCR_CTRL] = 5u;
}
