/* ----------------------------------------------------------------------------
 * gemm_accel.h
 * Register map and driver API for the systolic GEMM tile accelerator. The
 * offsets and windows here are exactly what rtl/wb_slave.v decodes. The driver
 * (gemm_driver.c) is written the way firmware would drive the real Wishbone
 * device; in this repository the device behind the MMIO accesses is a
 * behavioral model so the whole stack compiles and runs on the host, and the
 * SystemVerilog testbench replays the identical bus sequence against the RTL.
 *
 * Operand layout expected by the hardware (see rtl/gemm_top.v):
 *   A window : column-major (A transposed), byte k*N + i holds A[i][k]
 *   B window : row-major,                    byte k*N + j holds B[k][j]
 *   C window : word  i*N + j holds the signed 32-bit result C[i][j]
 * The driver packs four operand bytes per 32-bit Wishbone word.
 * ------------------------------------------------------------------------- */
#ifndef GEMM_ACCEL_H
#define GEMM_ACCEL_H

#include <stdint.h>
#include <stddef.h>

/* ---- control-block register byte offsets ---- */
#define GEMM_REG_CTRL     0x00u   /* W  [0]=START [1]=IRQ_EN [2]=IRQ_CLR      */
#define GEMM_REG_STATUS   0x04u   /* R  [0]=DONE  [1]=BUSY                    */
#define GEMM_REG_KLEN     0x08u   /* RW inner dimension K (1..KMAX)           */
#define GEMM_REG_MODE     0x0Cu   /* RW [0]=ACCUM                            */
#define GEMM_REG_NDIM     0x10u   /* R  compile-time N                       */
#define GEMM_REG_DATAW    0x14u   /* R  compile-time operand width           */
#define GEMM_REG_KMAX     0x18u   /* R  compile-time KMAX                    */
#define GEMM_REG_CYCLES   0x1Cu   /* R  START->DONE cycles of the last run   */

/* ---- memory windows (byte base addresses) ---- */
#define GEMM_WIN_A        0x1000u /* operand A^T, column-major bytes         */
#define GEMM_WIN_B        0x2000u /* operand B,   row-major bytes            */
#define GEMM_WIN_C        0x3000u /* result C, one 32-bit word per element   */

#define GEMM_CTRL_START   (1u << 0)
#define GEMM_CTRL_IRQ_EN  (1u << 1)
#define GEMM_CTRL_IRQ_CLR (1u << 2)
#define GEMM_STATUS_DONE  (1u << 0)
#define GEMM_STATUS_BUSY  (1u << 1)
#define GEMM_MODE_ACCUM   (1u << 0)

/* Compile-time shape of the elaborated hardware (filled in by the host). */
typedef struct {
    int n;            /* systolic array dimension (tile is n x n)          */
    int data_width;   /* signed operand width, bits                        */
    int acc_width;    /* result width, bits                                */
    int kmax;         /* maximum K per single run                          */
} gemm_shape_t;

/* ---- Golden reference (gemm_ref.c) ----
 * One tile product with an accumulate flag:
 *   C[i][j] = (accum ? C[i][j] : 0) + sum_{k=0..K-1} A[i][k]*B[k][j]
 * A is row-major N x K (a[i*K+k]); B is row-major K x N (b[k*N+j]); C is
 * row-major N x N (c[i*N+j]). Accumulates in int64 so it is bit-exact against
 * the ACC_WIDTH hardware accumulators. */
void gemm_tile_ref(const int8_t *a, const int8_t *b, int n, int K,
                   int accum, int32_t *c);

/* Full tiled GEMM reference: C[M x P] = A[M x Kc] * B[Kc x P], row-major,
 * signed 8-bit operands, 32-bit result. Used to check the driver's tiling. */
void gemm_ref_full(const int8_t *A, const int8_t *B,
                   int M, int Kc, int P, int32_t *C);

/* Two's-complement helpers shared by host + driver. */
int64_t  gemm_sign_extend(uint64_t raw, int width);
uint32_t gemm_pack4(const int8_t *lanes);     /* four int8 lanes -> LE word */

/* ---- MMIO driver + behavioral device model (gemm_driver.c) ---- */
typedef struct gemm_device gemm_device_t;

gemm_device_t *gemm_dev_create(const gemm_shape_t *shape);
void           gemm_dev_destroy(gemm_device_t *dev);

/* Raw MMIO accessors (what the firmware pokes). */
uint32_t gemm_reg_read (gemm_device_t *dev, uint32_t off);
void     gemm_reg_write(gemm_device_t *dev, uint32_t off, uint32_t val);

/* Driver routines. a_col is the column-major A^T tile (K*N bytes); b_row is the
 * row-major B tile (K*N bytes). Return 0 on success. */
int gemm_load_a  (gemm_device_t *dev, const int8_t *a_col, int K);
int gemm_load_b  (gemm_device_t *dev, const int8_t *b_row, int K);
int gemm_run     (gemm_device_t *dev, int K, int accum);   /* START, wait DONE */
int gemm_read_c  (gemm_device_t *dev, int32_t *c_out);     /* N*N words         */
uint32_t gemm_last_cycles(gemm_device_t *dev);

/* One complete tile transaction (load A/B, run, optionally read C back). */
int gemm_run_tile(gemm_device_t *dev, const int8_t *a_col, const int8_t *b_row,
                  int K, int accum, int32_t *c_out);

/* High-level tiled GEMM built on the tile engine: C[M x P] = A[M x Kc]*B[Kc x P].
 * Splits the output into n x n tiles and the K dimension into <= KMAX chunks,
 * accumulating in hardware. Zero-pads partial edge tiles. Returns 0 on success. */
int gemm_matmul(gemm_device_t *dev, const int8_t *A, const int8_t *B,
                int M, int Kc, int P, int32_t *C);

#endif /* GEMM_ACCEL_H */
