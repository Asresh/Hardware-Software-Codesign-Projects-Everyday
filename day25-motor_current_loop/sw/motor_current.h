// Author: Asresh
#ifndef MOTOR_CURRENT_H
#define MOTOR_CURRENT_H
#include <stdint.h>

enum {
    MC_CTRL = 0x00, MC_GAIN_Q8 = 0x04, MC_TRIP = 0x08,
    MC_REFERENCE = 0x0c, MC_MEASURED = 0x10, MC_DOORBELL = 0x14,
    MC_STATUS = 0x18, MC_DUTY = 0x1c, MC_JOBS = 0x20, MC_IRQ_STATUS = 0x24
};
enum { MC_FLAG_FAULT = 1u, MC_FLAG_SAT_HI = 2u, MC_FLAG_SAT_LO = 4u };

struct mc_result { uint16_t duty; uint8_t flags; };
struct mc_device { volatile uint32_t *base; };

struct mc_result mc_reference(int16_t reference, int16_t measured,
                              uint8_t gain_q8, uint16_t trip, int external_fault);
uint32_t mc_baseline_cycles(int16_t reference, int16_t measured,
                            uint8_t gain_q8, uint16_t trip, int external_fault);
void mc_configure(struct mc_device *dev, uint8_t gain_q8, uint16_t trip);
int mc_submit(struct mc_device *dev, int16_t reference, int16_t measured,
              int external_fault, uint32_t timeout, struct mc_result *result);
void mc_isr(struct mc_device *dev);
#endif
