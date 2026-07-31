/* ---------------------------------------------------------------------------
 * sfu_ref.c
 * The software golden model. For each request k it reads (op,a,b) from the
 * request stream and writes (op,r0,r1) to out[k*3 ..], using the shared
 * sfu_eval() primitive - the exact fixed-point CORDIC the hardware runs. It is
 * the reference every other implementation is measured against; the hardware
 * must reproduce it bit for bit.
 * ------------------------------------------------------------------------- */
#include "sfu_accel.h"

void sfu_reference(const uint32_t *req, uint32_t count, uint32_t *out)
{
    for (uint32_t k = 0; k < count; k++) {
        uint32_t op = req[k * SFU_ENTRY_WORDS + 0];
        int32_t  a  = (int32_t)req[k * SFU_ENTRY_WORDS + 1];
        int32_t  b  = (int32_t)req[k * SFU_ENTRY_WORDS + 2];
        int32_t  r0, r1;
        sfu_eval(op, a, b, &r0, &r1);
        out[k * 3 + 0] = op;
        out[k * 3 + 1] = (uint32_t)r0;
        out[k * 3 + 2] = (uint32_t)r1;
    }
}
