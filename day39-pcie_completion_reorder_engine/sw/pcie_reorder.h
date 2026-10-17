/* Author: Asresh */
#ifndef PCIE_REORDER_H
#define PCIE_REORDER_H
#include <stddef.h>
#include <stdint.h>
enum { PCR_CTRL=0, PCR_STATUS=1, PCR_TARGET=2, PCR_ISSUED=3,
       PCR_COMPLETED=4, PCR_RETIRED=5, PCR_OOO=6, PCR_ERRORS=7,
       PCR_HIGH_WATER=8 };
typedef struct { volatile uint32_t *regs; } pcr_device;
typedef struct { uint16_t id; uint32_t opaque; uint32_t data; uint8_t status; } pcr_result;
int pcr_configure(pcr_device *dev, uint32_t target_count);
void pcr_ack_irq(pcr_device *dev);
pcr_result pcr_reference(uint16_t id, uint32_t opaque);
uint64_t pcr_checksum(const pcr_result *results, size_t count);
#endif
