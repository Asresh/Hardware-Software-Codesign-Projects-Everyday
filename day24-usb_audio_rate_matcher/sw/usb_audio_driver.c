/* Author: Asresh
 * Diagram: configure target/gain -> enable endpoint -> poll/IRQ -> acknowledge
 */
#include "usb_audio.h"
static void wr(struct ua_device *d, unsigned off, uint32_t v) { d->regs[off/4u]=v; }
static uint32_t rd(struct ua_device *d, unsigned off) { return d->regs[off/4u]; }
void ua_configure(struct ua_device *d, uint16_t target, uint16_t gain_q8) {
    wr(d,UA_TARGET,target); wr(d,UA_GAIN,gain_q8); d->completed=0;
}
void ua_start(struct ua_device *d) { wr(d,UA_CTRL,3u); }
void ua_move_samples(struct ua_device *d, const struct ua_sample *samples, size_t count) {
    if (d->push_sample == 0) return;
    for (size_t i=0;i<count;i++) d->push_sample(d->stream_cookie,samples[i],i+1u==count);
}
int ua_wait(struct ua_device *d, uint32_t timeout) {
    while (timeout-- != 0u) if ((rd(d,UA_STATUS)&2u)!=0u) return 0;
    return -1;
}
void ua_isr(struct ua_device *d) { d->completed=rd(d,UA_COUNT); wr(d,UA_IRQ,1u); }
