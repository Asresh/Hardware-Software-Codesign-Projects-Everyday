/* Author: Asresh
 * Diagram: policy/config -> MMIO driver -> USB rate-matcher -> completion ISR
 */
#ifndef USB_AUDIO_H
#define USB_AUDIO_H
#include <stdint.h>
#include <stddef.h>
enum { UA_CTRL=0x00, UA_TARGET=0x04, UA_GAIN=0x08, UA_STATUS=0x0c,
       UA_COUNT=0x10, UA_IRQ=0x14 };
struct ua_sample { int16_t prev, curr; uint16_t fill; };
int16_t ua_reference(struct ua_sample s, uint16_t target, uint16_t gain_q8);
uint64_t ua_baseline_cycles(size_t samples);
struct ua_device {
    volatile uint32_t *regs;
    uint32_t completed;
    void (*push_sample)(void *cookie, struct ua_sample sample, int last);
    void *stream_cookie;
};
void ua_configure(struct ua_device *d, uint16_t target, uint16_t gain_q8);
void ua_start(struct ua_device *d);
void ua_move_samples(struct ua_device *d, const struct ua_sample *samples, size_t count);
int ua_wait(struct ua_device *d, uint32_t timeout);
void ua_isr(struct ua_device *d);
#endif
