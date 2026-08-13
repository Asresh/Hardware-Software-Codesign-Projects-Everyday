#include "hid_fusion.h"

enum { CMD_CONFIG = 0x01, CMD_FRAME = 0x10, CMD_STATUS = 0x20, CMD_RESULT = 0x21 };

static void select_bus(struct hidf_spi_bus *bus, int active) { bus->chip_select(bus->ctx, active); }
static uint8_t xfer(struct hidf_spi_bus *bus, uint8_t value) { return bus->transfer(bus->ctx, value); }

int hidf_configure(struct hidf_spi_bus *bus, uint16_t baseline, uint32_t threshold)
{
    if (bus == NULL || bus->transfer == NULL || bus->chip_select == NULL)
        return -1;
    select_bus(bus, 1);
    (void)xfer(bus, CMD_CONFIG);
    (void)xfer(bus, (uint8_t)(baseline >> 8));
    (void)xfer(bus, (uint8_t)baseline);
    (void)xfer(bus, (uint8_t)(threshold >> 16));
    (void)xfer(bus, (uint8_t)(threshold >> 8));
    (void)xfer(bus, (uint8_t)threshold);
    select_bus(bus, 0);
    return 0;
}

int hidf_submit(struct hidf_spi_bus *bus, const uint16_t sample[HIDF_CHANNELS])
{
    size_t i;
    if (bus == NULL || sample == NULL)
        return -1;
    select_bus(bus, 1);
    (void)xfer(bus, CMD_FRAME);
    for (i = 0; i < HIDF_CHANNELS; ++i) {
        (void)xfer(bus, (uint8_t)(sample[i] >> 8));
        (void)xfer(bus, (uint8_t)sample[i]);
    }
    select_bus(bus, 0);
    return 0;
}

int hidf_poll_complete(struct hidf_spi_bus *bus, unsigned attempts)
{
    while (attempts-- != 0u) {
        uint8_t status;
        select_bus(bus, 1);
        (void)xfer(bus, CMD_STATUS);
        status = xfer(bus, 0);
        select_bus(bus, 0);
        if ((status & 2u) != 0u)
            return 0;
    }
    return -1;
}

int hidf_read_result(struct hidf_spi_bus *bus, struct hidf_result *out)
{
    uint8_t b[9];
    size_t i;
    if (bus == NULL || out == NULL)
        return -1;
    select_bus(bus, 1);
    (void)xfer(bus, CMD_RESULT);
    for (i = 0; i < sizeof b; ++i)
        b[i] = xfer(bus, 0);
    select_bus(bus, 0);
    out->x = (uint16_t)(((uint16_t)b[0] << 8) | b[1]);
    out->y = (uint16_t)(((uint16_t)b[2] << 8) | b[3]);
    out->pressure = ((uint32_t)b[4] << 24) | ((uint32_t)b[5] << 16) |
                    ((uint32_t)b[6] << 8) | b[7];
    out->flags = b[8];
    return 0;
}
