/* ----------------------------------------------------------------------------
 * fir_accel.h
 * Register map and driver API for the streaming FIR accelerator. This is the
 * exact same offset layout implemented by rtl/axi_lite_regfile.v; the register
 * accessors below are written the way they would be for the real SoC (MMIO
 * through a volatile pointer), and are exercised in software against a
 * behavioral model of the device (see fir_driver.c) before the identical
 * programming sequence is replayed against the RTL by the SystemVerilog
 * testbench.
 * ------------------------------------------------------------------------- */
#ifndef FIR_ACCEL_H
#define FIR_ACCEL_H

#include <stdint.h>
#include <stddef.h>

/* ---- CSR byte offsets (see rtl/axi_lite_regfile.v) ---- */
#define FIR_REG_CTRL        0x00u   /* [0]=START [1]=IRQ_EN [2]=SOFT_CLR      */
#define FIR_REG_STATUS      0x04u   /* [0]=DONE  [1]=BUSY                     */
#define FIR_REG_LENGTH      0x08u   /* number of samples in the job          */
#define FIR_REG_TAP_COUNT   0x0Cu   /* RO: compile-time TAPS                  */
#define FIR_REG_DATA_WIDTH  0x10u   /* RO: compile-time DATA_WIDTH            */
#define FIR_REG_SAMPLES_OUT 0x14u   /* RO: results produced                  */
#define FIR_REG_IN_LEVEL    0x18u   /* RO: input FIFO occupancy              */
#define FIR_REG_OUT_LEVEL   0x1Cu   /* RO: output FIFO occupancy             */
#define FIR_REG_COEF_BASE   0x40u   /* COEF[i] at COEF_BASE + 4*i            */

#define FIR_CTRL_START      (1u << 0)
#define FIR_CTRL_IRQ_EN     (1u << 1)
#define FIR_CTRL_SOFT_CLR   (1u << 2)
#define FIR_STATUS_DONE     (1u << 0)
#define FIR_STATUS_BUSY     (1u << 1)

/* Compile-time shape of the elaborated hardware, filled in by the host. */
typedef struct {
    int taps;          /* number of filter taps                */
    int data_width;    /* input sample width, bits             */
    int coef_width;    /* coefficient width, bits              */
    int acc_width;     /* result width, bits (== data+coef+ceil(log2 taps)) */
} fir_shape_t;

/* ---- Golden reference (fir_ref.c) ----
 * Streaming FIR, zero initial state, full precision:
 *   y[n] = sum_{k=0..taps-1} h[k] * x[n-k],  x[m<0] = 0,  n in [0,len)
 * Accumulates in int64_t so the result is bit-exact against the ACC_WIDTH
 * hardware datapath (acc_width <= 63 for every supported parameter set). */
void fir_ref(const int64_t *h, int taps,
             const int64_t *x, int len,
             int64_t *y);

/* ---- MMIO driver (fir_driver.c) ----
 * A "device" is a volatile register window plus its streaming ports. In this
 * repository the device is a software behavioral model; on real silicon the
 * same functions drive the AXI4-Lite CSRs and the AXI4-Stream DMA. */
typedef struct fir_device fir_device_t;

fir_device_t *fir_dev_create(const fir_shape_t *shape, int fifo_depth);
void          fir_dev_destroy(fir_device_t *dev);

/* Driver routines (what the firmware would call). Return 0 on success. */
int  fir_reset       (fir_device_t *dev);
int  fir_load_coefs  (fir_device_t *dev, const int64_t *h, int taps);
int  fir_run_job     (fir_device_t *dev,
                      const int64_t *x, int len,
                      int64_t *y_out);          /* configures, streams, waits DONE, drains */

/* Raw MMIO accessors, for illustration / unit tests. */
uint32_t fir_reg_read (fir_device_t *dev, uint32_t off);
void     fir_reg_write(fir_device_t *dev, uint32_t off, uint32_t val);

/* Sign/format helpers shared by host + driver. */
int64_t  fir_sign_extend(uint64_t raw, int width);
uint64_t fir_mask_bits  (int64_t v, int width);   /* two's-complement, width bits */

#endif /* FIR_ACCEL_H */
