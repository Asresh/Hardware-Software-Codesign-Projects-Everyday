/* Author: Asresh */
#include "vibration_monitor.h"
void vm_configure(volatile uint32_t *regs, const int16_t coeff[4]) {
    regs[VM_CTRL] = 2u;
    for (unsigned i = 0; i < 4; ++i) regs[VM_COEFF0 + i] = (uint16_t)coeff[i];
    regs[VM_CTRL] = 1u;
}
struct vm_result vm_read_result(volatile uint32_t *regs) {
    struct vm_result r;
    r.bin = (uint8_t)regs[VM_PEAK_BIN];
    r.power = ((uint64_t)regs[VM_POWER_HI] << 32) | regs[VM_POWER_LO];
    regs[VM_STATUS] = 1u;
    return r;
}
