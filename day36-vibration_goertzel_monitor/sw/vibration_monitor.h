/* Author: Asresh */
#ifndef VIBRATION_MONITOR_H
#define VIBRATION_MONITOR_H
#include <stddef.h>
#include <stdint.h>
enum { VM_CTRL=0, VM_STATUS=1, VM_SAMPLES=2, VM_FRAMES=3, VM_PEAK_BIN=4,
       VM_POWER_LO=5, VM_POWER_HI=6, VM_COEFF0=7 };
struct vm_result { uint8_t bin; uint64_t power; };
void vm_configure(volatile uint32_t *regs, const int16_t coeff[4]);
struct vm_result vm_read_result(volatile uint32_t *regs);
void vm_reference(const int16_t *samples, size_t count, const int16_t coeff[4], struct vm_result *out);
#endif
