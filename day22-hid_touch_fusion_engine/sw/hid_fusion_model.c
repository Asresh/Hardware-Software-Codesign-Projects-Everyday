#include "hid_fusion.h"

void hidf_reference(const uint16_t sample[HIDF_CHANNELS], uint16_t baseline,
                    uint32_t threshold, struct hidf_result *out)
{
    uint32_t corrected[HIDF_CHANNELS];
    uint32_t total = 0;
    uint32_t right = 0;
    uint32_t bottom = 0;
    size_t i;

    for (i = 0; i < HIDF_CHANNELS; ++i) {
        corrected[i] = sample[i] > baseline ? (uint32_t)sample[i] - baseline : 0u;
        total += corrected[i];
        if ((i & 3u) == 1u || (i & 3u) == 3u)
            right += corrected[i];
        if ((i & 3u) == 2u || (i & 3u) == 3u)
            bottom += corrected[i];
    }

    out->pressure = total;
    out->flags = total >= threshold ? HIDF_FLAG_TOUCH : 0u;
    if (out->flags != 0u && total != 0u) {
        out->x = (uint16_t)(((uint64_t)right * HIDF_COORD_MAX) / total);
        out->y = (uint16_t)(((uint64_t)bottom * HIDF_COORD_MAX) / total);
    } else {
        out->x = 512u;
        out->y = 512u;
    }
}
