/* ----------------------------------------------------------------------------
 * gemm_ref.c
 * Golden software model of the GEMM computation and the shared two's-complement
 * helpers. This is the reference the hardware is diff-tested against and the
 * scalar baseline the speedup is measured relative to.
 * ------------------------------------------------------------------------- */
#include "gemm_accel.h"

/* One n x n tile product. A is row-major n x K (a[i*K+k]); B is row-major
 * K x n (b[k*n+j]); C is row-major n x n. The inner loop is one multiply-
 * accumulate per (i,j,k): n*n*K MACs for the tile -- this count is the scalar-
 * CPU baseline the array is compared against. Accumulation is done in int64 and
 * truncated to 32 bits on store, matching the hardware accumulators exactly. */
void gemm_tile_ref(const int8_t *a, const int8_t *b, int n, int K,
                   int accum, int32_t *c)
{
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            int64_t acc = accum ? (int64_t)c[i*n + j] : 0;
            for (int k = 0; k < K; k++)
                acc += (int64_t)a[i*K + k] * (int64_t)b[k*n + j];
            c[i*n + j] = (int32_t)acc;      /* wraps mod 2^32, as the RTL does */
        }
    }
}

/* Full row-major GEMM: C[M x P] = A[M x Kc] * B[Kc x P]. */
void gemm_ref_full(const int8_t *A, const int8_t *B,
                   int M, int Kc, int P, int32_t *C)
{
    for (int i = 0; i < M; i++)
        for (int j = 0; j < P; j++) {
            int64_t acc = 0;
            for (int k = 0; k < Kc; k++)
                acc += (int64_t)A[i*Kc + k] * (int64_t)B[k*P + j];
            C[i*P + j] = (int32_t)acc;
        }
}

/* Sign-extend a width-bit two's-complement raw value into int64_t. */
int64_t gemm_sign_extend(uint64_t raw, int width)
{
    uint64_t mask = (width >= 64) ? ~0ull : ((1ull << width) - 1u);
    raw &= mask;
    uint64_t sign = 1ull << (width - 1);
    if (raw & sign)
        return (int64_t)(raw | ~mask);
    return (int64_t)raw;
}

/* Pack four signed 8-bit lanes into a little-endian 32-bit word (lane 0 in the
 * low byte), matching how the hardware slices a bus word into buffer bytes. */
uint32_t gemm_pack4(const int8_t *lanes)
{
    return  ((uint32_t)(uint8_t)lanes[0])        |
            ((uint32_t)(uint8_t)lanes[1] <<  8)  |
            ((uint32_t)(uint8_t)lanes[2] << 16)  |
            ((uint32_t)(uint8_t)lanes[3] << 24);
}
