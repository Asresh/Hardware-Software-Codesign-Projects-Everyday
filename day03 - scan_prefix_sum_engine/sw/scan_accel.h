/* ---------------------------------------------------------------------------
 * scan_accel.h
 * Register map, descriptor definition and driver / reference API for the
 * parallel prefix-sum (scan) engine. Shared by the bare-metal driver, the
 * software golden model, the scalar baseline and the vector generator so that
 * the hardware, the firmware and the test vectors never drift apart.
 * ------------------------------------------------------------------------- */
#ifndef SCAN_ACCEL_H
#define SCAN_ACCEL_H

#include <stdint.h>
#include <stddef.h>

/* ---- APB register byte offsets (must match rtl/scan_top.v) ---- */
#define SCAN_REG_IDENT   0x00u
#define SCAN_REG_CTRL    0x04u
#define SCAN_REG_STATUS  0x08u
#define SCAN_REG_SRC     0x0Cu
#define SCAN_REG_DST     0x10u
#define SCAN_REG_LEN     0x14u
#define SCAN_REG_MODE    0x18u
#define SCAN_REG_CYCLES  0x1Cu

/* ---- CTRL write bits ---- */
#define SCAN_CTRL_START   0x1u
#define SCAN_CTRL_IRQ_EN  0x2u
#define SCAN_CTRL_IRQ_CLR 0x4u

/* ---- STATUS read bits ---- */
#define SCAN_STATUS_DONE  0x1u
#define SCAN_STATUS_BUSY  0x2u
#define SCAN_STATUS_IRQ   0x4u

/* ---- MODE bits ---- */
#define SCAN_MODE_INCLUSIVE 0x0u
#define SCAN_MODE_EXCLUSIVE 0x1u

#define SCAN_IDENT_VALUE  0x5CA40003u

/* Memory-mapped CSR image (32-bit registers on 4-byte stride). */
typedef struct {
    volatile uint32_t ident;   /* 0x00 */
    volatile uint32_t ctrl;    /* 0x04 */
    volatile uint32_t status;  /* 0x08 */
    volatile uint32_t src;     /* 0x0C */
    volatile uint32_t dst;     /* 0x10 */
    volatile uint32_t len;     /* 0x14 */
    volatile uint32_t mode;    /* 0x18 */
    volatile uint32_t cycles;  /* 0x1C */
} scan_csr_t;

/* One scan job (a DMA descriptor). */
typedef struct {
    uint32_t src_addr;   /* source base, word address     */
    uint32_t dst_addr;   /* destination base, word address */
    uint32_t len;        /* element count                 */
    int      exclusive;  /* 1 = exclusive, 0 = inclusive  */
} scan_desc_t;

/* ---- bare-metal driver (sw/scan_driver.c) ----
 * Programs the descriptor, starts the engine, waits for completion and returns
 * the hardware cycle count from the CYCLES register. */
uint32_t scan_run(scan_csr_t *csr, const scan_desc_t *d);

/* ---- software golden model (sw/scan_ref.c) ----
 * Exact 32-bit-wraparound prefix sum used to check the hardware. */
void scan_reference(const uint32_t *in, uint32_t *out, uint32_t len, int exclusive);

/* ---- scalar baseline (sw/scan_baseline.c) ----
 * A software-only prefix sum plus its documented single-issue cycle model. */
void     scan_baseline(const uint32_t *in, uint32_t *out, uint32_t len, int exclusive);
uint64_t scan_baseline_cycles(uint32_t len);   /* SCAN_CPE cycles / element */

#define SCAN_CPE 3u   /* load + add + store dependency chain, single-issue */

#endif /* SCAN_ACCEL_H */
