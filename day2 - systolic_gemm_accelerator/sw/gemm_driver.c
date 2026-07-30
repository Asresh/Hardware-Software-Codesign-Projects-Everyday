/* ----------------------------------------------------------------------------
 * gemm_driver.c
 * Firmware-side driver for the systolic GEMM accelerator plus a compact
 * behavioral model of the device it talks to. The driver functions poke the
 * Wishbone CSRs and the A/B/C windows by offset, exactly as they would on real
 * silicon; here the "device" behind those accesses is a software model so the
 * driver can be exercised end to end on the host. The SystemVerilog testbench
 * replays the identical A/B write, KLEN/MODE, START, C read sequence against
 * the actual RTL.
 * ------------------------------------------------------------------------- */
#include "gemm_accel.h"
#include <stdlib.h>
#include <string.h>

#define GEMM_MAX_N     8
#define GEMM_MAX_KMAX  64
#define GEMM_MAX_BYTES (GEMM_MAX_N * GEMM_MAX_KMAX)

struct gemm_device {
    gemm_shape_t shape;

    int      klen;
    int      accum;
    int      irq_en;
    int      busy;
    int      done;
    uint32_t cycles;

    int8_t   a_buf[GEMM_MAX_BYTES];    /* column-major A^T, byte k*N+i = A[i][k] */
    int8_t   b_buf[GEMM_MAX_BYTES];    /* row-major B,      byte k*N+j = B[k][j] */
    int64_t  acc[GEMM_MAX_N * GEMM_MAX_N];   /* persistent output accumulators   */
};

gemm_device_t *gemm_dev_create(const gemm_shape_t *shape)
{
    if (shape->n > GEMM_MAX_N || shape->kmax > GEMM_MAX_KMAX) return NULL;
    gemm_device_t *dev = (gemm_device_t *)calloc(1, sizeof(*dev));
    if (!dev) return NULL;
    dev->shape = *shape;
    dev->klen  = 1;
    return dev;
}

void gemm_dev_destroy(gemm_device_t *dev) { free(dev); }

/* The hidden RTL behavior: on START, run one tile product over the buffered
 * operands, clearing the accumulators first unless accumulate mode is set. */
static void dev_compute(gemm_device_t *dev)
{
    int n = dev->shape.n, K = dev->klen;
    if (!dev->accum)
        for (int e = 0; e < n * n; e++) dev->acc[e] = 0;
    for (int k = 0; k < K; k++)
        for (int i = 0; i < n; i++)
            for (int j = 0; j < n; j++)
                dev->acc[i*n + j] += (int64_t)dev->a_buf[k*n + i] *
                                     (int64_t)dev->b_buf[k*n + j];
    dev->busy   = 0;
    dev->done   = 1;
    dev->cycles = (uint32_t)(K + 2*n + 2);   /* model estimate; real count is RTL's */
}

/* --- raw MMIO --- */
uint32_t gemm_reg_read(gemm_device_t *dev, uint32_t off)
{
    if (off >= GEMM_WIN_C && off < GEMM_WIN_C + 4u * (uint32_t)(dev->shape.n * dev->shape.n)) {
        int e = (int)((off - GEMM_WIN_C) >> 2);
        return (uint32_t)(int32_t)dev->acc[e];
    }
    switch (off) {
    case GEMM_REG_STATUS: return (dev->done ? GEMM_STATUS_DONE : 0u) |
                                 (dev->busy ? GEMM_STATUS_BUSY : 0u);
    case GEMM_REG_KLEN:   return (uint32_t)dev->klen;
    case GEMM_REG_MODE:   return (uint32_t)dev->accum;
    case GEMM_REG_NDIM:   return (uint32_t)dev->shape.n;
    case GEMM_REG_DATAW:  return (uint32_t)dev->shape.data_width;
    case GEMM_REG_KMAX:   return (uint32_t)dev->shape.kmax;
    case GEMM_REG_CYCLES: return dev->cycles;
    case GEMM_REG_CTRL:   return dev->irq_en ? GEMM_CTRL_IRQ_EN : 0u;
    default:              return 0xDEADBEEFu;
    }
}

void gemm_reg_write(gemm_device_t *dev, uint32_t off, uint32_t val)
{
    int n = dev->shape.n;
    if (off >= GEMM_WIN_A && off < GEMM_WIN_A + (uint32_t)(n * dev->shape.kmax)) {
        int base = (int)(off - GEMM_WIN_A);   /* byte index = 4*wordidx */
        for (int b = 0; b < 4; b++)
            dev->a_buf[base + b] = (int8_t)((val >> (8*b)) & 0xFFu);
        return;
    }
    if (off >= GEMM_WIN_B && off < GEMM_WIN_B + (uint32_t)(n * dev->shape.kmax)) {
        int base = (int)(off - GEMM_WIN_B);
        for (int b = 0; b < 4; b++)
            dev->b_buf[base + b] = (int8_t)((val >> (8*b)) & 0xFFu);
        return;
    }
    switch (off) {
    case GEMM_REG_CTRL:
        dev->irq_en = (val & GEMM_CTRL_IRQ_EN) ? 1 : 0;
        if (val & GEMM_CTRL_IRQ_CLR) dev->done = 0;
        if (val & GEMM_CTRL_START) { dev->busy = 1; dev->done = 0; dev_compute(dev); }
        break;
    case GEMM_REG_KLEN: dev->klen  = (int)val;        break;
    case GEMM_REG_MODE: dev->accum = (val & GEMM_MODE_ACCUM) ? 1 : 0; break;
    default: break;
    }
}

/* --- driver API (firmware) --- */
int gemm_load_a(gemm_device_t *dev, const int8_t *a_col, int K)
{
    int n = dev->shape.n, nbytes = K * n;
    if (K < 1 || K > dev->shape.kmax) return -1;
    for (int w = 0; w < nbytes / 4; w++)
        gemm_reg_write(dev, GEMM_WIN_A + 4u * (uint32_t)w, gemm_pack4(&a_col[4*w]));
    return 0;
}

int gemm_load_b(gemm_device_t *dev, const int8_t *b_row, int K)
{
    int n = dev->shape.n, nbytes = K * n;
    if (K < 1 || K > dev->shape.kmax) return -1;
    for (int w = 0; w < nbytes / 4; w++)
        gemm_reg_write(dev, GEMM_WIN_B + 4u * (uint32_t)w, gemm_pack4(&b_row[4*w]));
    return 0;
}

int gemm_run(gemm_device_t *dev, int K, int accum)
{
    if (K < 1 || K > dev->shape.kmax) return -1;
    gemm_reg_write(dev, GEMM_REG_KLEN, (uint32_t)K);
    gemm_reg_write(dev, GEMM_REG_MODE, accum ? GEMM_MODE_ACCUM : 0u);
    gemm_reg_write(dev, GEMM_REG_CTRL, GEMM_CTRL_START | GEMM_CTRL_IRQ_EN);

    unsigned guard = 0;
    while (!(gemm_reg_read(dev, GEMM_REG_STATUS) & GEMM_STATUS_DONE))
        if (++guard > 1u << 20) return -2;      /* stuck */
    return 0;
}

int gemm_read_c(gemm_device_t *dev, int32_t *c_out)
{
    int nn = dev->shape.n * dev->shape.n;
    for (int e = 0; e < nn; e++)
        c_out[e] = (int32_t)gemm_reg_read(dev, GEMM_WIN_C + 4u * (uint32_t)e);
    return 0;
}

uint32_t gemm_last_cycles(gemm_device_t *dev)
{
    return gemm_reg_read(dev, GEMM_REG_CYCLES);
}

int gemm_run_tile(gemm_device_t *dev, const int8_t *a_col, const int8_t *b_row,
                  int K, int accum, int32_t *c_out)
{
    int rc;
    if ((rc = gemm_load_a(dev, a_col, K)) != 0) return rc;
    if ((rc = gemm_load_b(dev, b_row, K)) != 0) return rc;
    if ((rc = gemm_run(dev, K, accum))    != 0) return rc;
    if (c_out) return gemm_read_c(dev, c_out);
    return 0;
}

/* High-level tiled GEMM: C[M x P] = A[M x Kc] * B[Kc x P], row-major. Splits the
 * output into n x n tiles and K into <= KMAX chunks, accumulating in hardware.
 * Partial edge tiles are zero-padded so the valid region stays exact. */
int gemm_matmul(gemm_device_t *dev, const int8_t *A, const int8_t *B,
                int M, int Kc, int P, int32_t *C)
{
    int n = dev->shape.n, kmax = dev->shape.kmax;
    static int8_t  a_col[GEMM_MAX_BYTES];
    static int8_t  b_row[GEMM_MAX_BYTES];
    static int32_t c_tile[GEMM_MAX_N * GEMM_MAX_N];

    for (int ti = 0; ti < M; ti += n) {
        for (int tj = 0; tj < P; tj += n) {
            int first = 1;
            for (int kb = 0; kb < Kc; kb += kmax) {
                int K = (Kc - kb < kmax) ? (Kc - kb) : kmax;
                /* column-major A^T tile: a_col[k*n + i] = A[ti+i][kb+k] */
                for (int k = 0; k < K; k++)
                    for (int i = 0; i < n; i++) {
                        int ai = ti + i, ak = kb + k;
                        a_col[k*n + i] = (ai < M) ? A[ai*Kc + ak] : 0;
                    }
                /* row-major B tile: b_row[k*n + j] = B[kb+k][tj+j] */
                for (int k = 0; k < K; k++)
                    for (int j = 0; j < n; j++) {
                        int bk = kb + k, bj = tj + j;
                        b_row[k*n + j] = (bj < P) ? B[bk*P + bj] : 0;
                    }
                int rc = gemm_run_tile(dev, a_col, b_row, K, first ? 0 : 1, NULL);
                if (rc != 0) return rc;
                first = 0;
            }
            gemm_read_c(dev, c_tile);
            for (int i = 0; i < n; i++)
                for (int j = 0; j < n; j++) {
                    int ci = ti + i, cj = tj + j;
                    if (ci < M && cj < P) C[ci*P + cj] = c_tile[i*n + j];
                }
        }
    }
    return 0;
}
