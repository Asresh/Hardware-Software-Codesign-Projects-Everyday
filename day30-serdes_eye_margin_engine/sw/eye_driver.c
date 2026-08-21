/* Author: Asresh */
#include "eye_margin.h"
int eye_run(struct eye_regs *regs, eye_push_fn push, void *context,
            const struct eye_point *points, size_t count, uint16_t limit,
            uint32_t timeout, struct eye_result *out) {
    size_t i;
    uint32_t polls;
    if (regs == NULL || push == NULL || points == NULL || out == NULL || count == 0 || count > EYE_MAX_POINTS || timeout == 0) return -1;
    if (regs->device_id != UINT32_C(0x45594530)) return -2;
    regs->error_limit = limit;
    regs->control = UINT32_C(3); /* START | IRQ_EN */
    for (i = 0; i < count; ++i) if (push(context, &points[i]) != 0) return -3;
    for (polls = 0; polls < timeout; ++polls) if ((regs->irq_status & 1u) != 0) break;
    if (polls == timeout) return -4;
    out->best_start = (uint8_t)regs->best_start;
    out->best_length = (uint16_t)regs->best_length;
    out->sample_count = (uint16_t)regs->sample_count;
    regs->irq_status = 1u; /* W1C */
    return 0;
}
