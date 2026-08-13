/* ----------------------------------------------------------------------------
 * fir_driver.c
 * The firmware-side driver for the FIR accelerator, plus a compact behavioral
 * model of the device it talks to. The driver functions (fir_reset,
 * fir_load_coefs, fir_run_job) are written exactly as they would be for the
 * real SoC: they poke AXI4-Lite CSRs by offset and move sample data over the
 * stream port. Here the "device" behind those accesses is a software model so
 * the driver can be compiled and run end to end on the host; the SystemVerilog
 * testbench replays the identical CTRL/LENGTH/COEF/START sequence against the
 * actual RTL.
 * ------------------------------------------------------------------------- */
#include "fir_accel.h"
#include <stdlib.h>
#include <string.h>

#define FIR_MAX_TAPS 64
#define FIR_MAX_LEN  8192

struct fir_device {
    fir_shape_t shape;
    int         fifo_depth;

    uint32_t    csr[64];                 /* word-addressed CSR shadow          */
    int64_t     coef[FIR_MAX_TAPS];

    int64_t     in_buf[FIR_MAX_LEN];     /* models the AXI4-Stream input path  */
    int         in_count;
    int64_t     out_buf[FIR_MAX_LEN];    /* models the AXI4-Stream output path */
    int         out_count;
    int         out_rd;

    int         length;
    int         busy;
    int         done;
    int         samples_out;
};

fir_device_t *fir_dev_create(const fir_shape_t *shape, int fifo_depth)
{
    fir_device_t *dev = (fir_device_t *)calloc(1, sizeof(*dev));
    if (!dev) return NULL;
    dev->shape      = *shape;
    dev->fifo_depth = fifo_depth;
    dev->csr[FIR_REG_TAP_COUNT   >> 2] = (uint32_t)shape->taps;
    dev->csr[FIR_REG_DATA_WIDTH  >> 2] = (uint32_t)shape->data_width;
    return dev;
}

void fir_dev_destroy(fir_device_t *dev) { free(dev); }

/* --- device-internal helpers (the hidden RTL behavior) --- */

static void dev_start_job(fir_device_t *dev)
{
    dev->length      = (int)dev->csr[FIR_REG_LENGTH >> 2];
    dev->in_count    = 0;
    dev->out_count   = 0;
    dev->out_rd      = 0;
    dev->samples_out = 0;
    if (dev->length == 0) { dev->busy = 0; dev->done = 1; }
    else                  { dev->busy = 1; dev->done = 0; }
}

/* Push one sample down the stream path; when the job's worth of samples has
 * arrived the datapath produces every result (this mirrors the RTL, which
 * emits one result per accepted sample and asserts DONE on the last one). */
static void dev_stream_push(fir_device_t *dev, int64_t sample)
{
    if (!dev->busy || dev->in_count >= dev->length) return;   /* gated by BUSY */
    dev->in_buf[dev->in_count++] = sample;
    if (dev->in_count == dev->length) {
        fir_ref(dev->coef, dev->shape.taps, dev->in_buf, dev->length, dev->out_buf);
        dev->out_count   = dev->length;
        dev->samples_out = dev->length;
        dev->busy        = 0;
        dev->done        = 1;
    }
}

static int dev_stream_pop(fir_device_t *dev, int64_t *out)
{
    if (dev->out_rd >= dev->out_count) return -1;
    *out = dev->out_buf[dev->out_rd++];
    return 0;
}

/* --- raw MMIO --- */

uint32_t fir_reg_read(fir_device_t *dev, uint32_t off)
{
    switch (off) {
    case FIR_REG_STATUS:
        return (dev->done ? FIR_STATUS_DONE : 0u) |
               (dev->busy ? FIR_STATUS_BUSY : 0u);
    case FIR_REG_SAMPLES_OUT: return (uint32_t)dev->samples_out;
    case FIR_REG_IN_LEVEL:    return (uint32_t)dev->in_count;
    case FIR_REG_OUT_LEVEL:   return (uint32_t)(dev->out_count - dev->out_rd);
    default:                  return dev->csr[(off & 0xFFu) >> 2];
    }
}

void fir_reg_write(fir_device_t *dev, uint32_t off, uint32_t val)
{
    if (off == FIR_REG_CTRL) {
        if (val & FIR_CTRL_SOFT_CLR) {
            dev->busy = dev->done = 0;
            dev->in_count = dev->out_count = dev->out_rd = dev->samples_out = 0;
        }
        if (val & FIR_CTRL_START) dev_start_job(dev);
        /* IRQ_EN is stored but the model reports completion by polling. */
        dev->csr[FIR_REG_CTRL >> 2] = (val & FIR_CTRL_IRQ_EN);
        return;
    }
    if (off >= FIR_REG_COEF_BASE &&
        off <  FIR_REG_COEF_BASE + 4u * (uint32_t)dev->shape.taps) {
        int i = (int)((off - FIR_REG_COEF_BASE) >> 2);
        dev->coef[i] = fir_sign_extend(val, dev->shape.coef_width);
        return;
    }
    dev->csr[(off & 0xFFu) >> 2] = val;
}

/* --- driver API (firmware) --- */

int fir_reset(fir_device_t *dev)
{
    fir_reg_write(dev, FIR_REG_CTRL, FIR_CTRL_SOFT_CLR);
    return 0;
}

int fir_load_coefs(fir_device_t *dev, const int64_t *h, int taps)
{
    if (taps != dev->shape.taps) return -1;
    for (int i = 0; i < taps; i++)
        fir_reg_write(dev, FIR_REG_COEF_BASE + 4u * (uint32_t)i,
                      (uint32_t)fir_mask_bits(h[i], dev->shape.coef_width));
    return 0;
}

/* Configure LENGTH, kick the job, stream the input, wait for DONE, drain the
 * results. This is the whole firmware transaction against the accelerator. */
int fir_run_job(fir_device_t *dev, const int64_t *x, int len, int64_t *y_out)
{
    if (len < 0 || len > FIR_MAX_LEN) return -1;

    fir_reg_write(dev, FIR_REG_LENGTH, (uint32_t)len);
    fir_reg_write(dev, FIR_REG_CTRL, FIR_CTRL_START | FIR_CTRL_IRQ_EN);

    for (int i = 0; i < len; i++)
        dev_stream_push(dev, x[i]);

    /* Poll for completion (the real driver would sleep on the irq instead). */
    unsigned guard = 0;
    while (!(fir_reg_read(dev, FIR_REG_STATUS) & FIR_STATUS_DONE)) {
        if (++guard > (unsigned)FIR_MAX_LEN + 16u) return -2;   /* stuck */
    }

    if ((int)fir_reg_read(dev, FIR_REG_SAMPLES_OUT) != len) return -3;

    for (int i = 0; i < len; i++)
        if (dev_stream_pop(dev, &y_out[i]) != 0) return -4;

    return 0;
}
