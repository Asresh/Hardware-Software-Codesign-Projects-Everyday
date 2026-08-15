/* Author: Asresh
 * Diagram: scalar load -> subtract -> multiply/divide -> interpolate -> store
 */
#include "usb_audio.h"
uint64_t ua_baseline_cycles(size_t samples) {
    /* Measured cost model: 2 loads + control math + interpolation + store. */
    return (uint64_t)samples * UINT64_C(18) + UINT64_C(12);
}
