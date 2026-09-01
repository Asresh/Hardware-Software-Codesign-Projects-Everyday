/* Author: Asresh */
#include "minimizer.h"
void minimizer_configure(minimizer_dev *dev, uint32_t seed) {
    dev->regs[MIN_CTRL] = 2u;
    dev->regs[MIN_SEED] = seed;
    dev->regs[MIN_IRQ] = 1u;
    dev->regs[MIN_CTRL] = 1u;
}
