#ifndef HID_FUSION_H
#define HID_FUSION_H

#include <stddef.h>
#include <stdint.h>

#define HIDF_CHANNELS 8u
#define HIDF_COORD_MAX 1023u
#define HIDF_FLAG_TOUCH 1u

struct hidf_result {
    uint16_t x;
    uint16_t y;
    uint32_t pressure;
    uint8_t flags;
};

struct hidf_spi_bus {
    uint8_t (*transfer)(void *ctx, uint8_t value);
    void (*chip_select)(void *ctx, int active);
    void *ctx;
};

void hidf_reference(const uint16_t sample[HIDF_CHANNELS], uint16_t baseline,
                    uint32_t threshold, struct hidf_result *out);
uint32_t hidf_baseline_cycles(void);
int hidf_configure(struct hidf_spi_bus *bus, uint16_t baseline, uint32_t threshold);
int hidf_submit(struct hidf_spi_bus *bus, const uint16_t sample[HIDF_CHANNELS]);
int hidf_poll_complete(struct hidf_spi_bus *bus, unsigned attempts);
int hidf_read_result(struct hidf_spi_bus *bus, struct hidf_result *out);

#endif
