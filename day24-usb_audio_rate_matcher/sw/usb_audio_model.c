/* Author: Asresh
 * Diagram: {prev,curr,fill} -> error/rate correction -> interpolation -> PCM16
 */
#include "usb_audio.h"
#include <limits.h>
int16_t ua_reference(struct ua_sample s, uint16_t target, uint16_t gain_q8) {
    int64_t error = (int64_t)target - (int64_t)s.fill;
    int64_t correction = (error * (int64_t)gain_q8) / 256;
    if (correction > 32767) correction = 32767;
    if (correction < -32768) correction = -32768;
    int64_t phase = 32768 + correction;
    if (phase < 0) phase = 0;
    if (phase > 65535) phase = 65535;
    int64_t delta = (int64_t)s.curr - (int64_t)s.prev;
    int64_t sample = (int64_t)s.prev + (delta * phase) / 65536;
    if (sample > INT16_MAX) sample = INT16_MAX;
    if (sample < INT16_MIN) sample = INT16_MIN;
    return (int16_t)sample;
}
