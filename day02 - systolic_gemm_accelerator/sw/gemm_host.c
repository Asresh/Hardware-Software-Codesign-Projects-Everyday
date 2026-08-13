/* ----------------------------------------------------------------------------
 * gemm_host.c
 * Host application for the systolic GEMM accelerator. It:
 *   1. builds a batch of single-tile jobs (random + directed corner cases +
 *      accumulate chains that mirror how software tiles a large K dimension),
 *   2. computes the golden result for each with the software reference,
 *   3. drives the firmware driver against the device model and checks it
 *      matches the golden (a software-side self-test of the whole driver path),
 *   4. exercises the high-level tiled gemm_matmul() on a non-tile-aligned
 *      matrix and checks it against a plain reference,
 *   5. writes $readmemh stimulus/golden plus a manifest for the SystemVerilog
 *      testbench, and
 *   6. measures the software-only baseline used for the hardware speedup.
 *
 * Usage:
 *   gemm_host --n N --data-width D --acc-width A --kmax K \
 *             --nrand R --seed S --outdir DIR
 * ------------------------------------------------------------------------- */
#include "gemm_accel.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_N     8
#define MAX_KMAX  64
#define MAX_BYTES (MAX_N * MAX_KMAX)
#define MAX_JOBS  400

enum { T_RANDOM, T_ZERO_A, T_ZERO_B, T_IDENTITY, T_MAXPOS,
       T_MAXNEG, T_MIX, T_ONELANE, T_CHAIN };

typedef struct { int K, accum, check, type; } jobdesc_t;

static int g_n, g_dw, g_aw, g_kmax;

/* xorshift64 RNG, deterministic for reproducible vectors. */
static uint64_t g_state;
static uint64_t xrand(void)
{
    uint64_t x = g_state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    return (g_state = x);
}
static int8_t rand_i8(void) { return (int8_t)(xrand() & 0xFFu); }
static int8_t max_pos(void)  { return (int8_t)(((uint64_t)1 << (g_dw-1)) - 1u); }  /* +127 */
static int8_t min_neg(void)  { return (int8_t)(-(int64_t)((uint64_t)1 << (g_dw-1))); } /* -128 */

/* Fill one job's A (row-major N x K, a[i*K+k]) and B (row-major K x N, b[k*N+j]). */
static void fill_job(int type, int K, int8_t *A, int8_t *B)
{
    int n = g_n;
    for (int i = 0; i < n*K; i++) A[i] = 0;
    for (int i = 0; i < K*n; i++) B[i] = 0;
    switch (type) {
    case T_ZERO_A:
        for (int k=0;k<K;k++) for (int j=0;j<n;j++) B[k*n+j]=rand_i8();
        break;
    case T_ZERO_B:
        for (int i=0;i<n;i++) for (int k=0;k<K;k++) A[i*K+k]=rand_i8();
        break;
    case T_IDENTITY:               /* K == n; A = identity so C == B tile */
        for (int i=0;i<n;i++) A[i*K+i]=1;
        for (int k=0;k<K;k++) for (int j=0;j<n;j++) B[k*n+j]=rand_i8();
        break;
    case T_MAXPOS:
        for (int i=0;i<n;i++) for (int k=0;k<K;k++) A[i*K+k]=max_pos();
        for (int k=0;k<K;k++) for (int j=0;j<n;j++) B[k*n+j]=max_pos();
        break;
    case T_MAXNEG:
        for (int i=0;i<n;i++) for (int k=0;k<K;k++) A[i*K+k]=max_pos();
        for (int k=0;k<K;k++) for (int j=0;j<n;j++) B[k*n+j]=min_neg();
        break;
    case T_MIX:
        for (int i=0;i<n;i++) for (int k=0;k<K;k++) A[i*K+k]=((i+k)&1)?min_neg():max_pos();
        for (int k=0;k<K;k++) for (int j=0;j<n;j++) B[k*n+j]=((k+j)&1)?max_pos():min_neg();
        break;
    case T_ONELANE:                /* only k=0 contributes */
        for (int i=0;i<n;i++) A[i*K+0]=rand_i8();
        for (int j=0;j<n;j++) B[0*n+j]=rand_i8();
        break;
    case T_RANDOM:
    case T_CHAIN:
    default:
        for (int i=0;i<n;i++) for (int k=0;k<K;k++) A[i*K+k]=rand_i8();
        for (int k=0;k<K;k++) for (int j=0;j<n;j++) B[k*n+j]=rand_i8();
        break;
    }
}

/* ---- fixed-width two's-complement hex writers ---- */
static void write_a_hex(const char *path, const int8_t *A, int K)   /* column-major */
{
    FILE *f = fopen(path, "w"); if (!f) { perror(path); exit(2); }
    for (int k=0;k<K;k++) for (int i=0;i<g_n;i++)
        fprintf(f, "%02x\n", (unsigned)(uint8_t)A[i*K+k]);
    fclose(f);
}
static void write_b_hex(const char *path, const int8_t *B, int K)   /* row-major */
{
    FILE *f = fopen(path, "w"); if (!f) { perror(path); exit(2); }
    for (int k=0;k<K;k++) for (int j=0;j<g_n;j++)
        fprintf(f, "%02x\n", (unsigned)(uint8_t)B[k*g_n+j]);
    fclose(f);
}
static void write_c_hex(const char *path, const int32_t *C)
{
    FILE *f = fopen(path, "w"); if (!f) { perror(path); exit(2); }
    for (int e=0;e<g_n*g_n;e++)
        fprintf(f, "%08x\n", (unsigned)(uint32_t)C[e]);
    fclose(f);
}

int main(int argc, char **argv)
{
    int nrand = 256;
    unsigned long seed = 12345;
    const char *outdir = "tb/vectors";
    g_n = 8; g_dw = 8; g_aw = 32; g_kmax = 64;

    for (int i = 1; i < argc - 1; i++) {
        if      (!strcmp(argv[i], "--n"))          g_n    = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--data-width")) g_dw   = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--acc-width"))  g_aw   = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--kmax"))       g_kmax = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--nrand"))      nrand  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed"))       seed   = strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--outdir"))     outdir = argv[++i];
    }
    g_state = seed ? seed : 0x9E3779B97F4A7C15ull;

    if (g_n < 1 || g_n > MAX_N || g_dw != 8 || g_aw != 32 ||
        g_kmax < g_n || g_kmax > MAX_KMAX || nrand < 0) {
        fprintf(stderr, "parameters out of range (n 1..%d, data-width 8, "
                "acc-width 32, kmax n..%d)\n", MAX_N, MAX_KMAX);
        return 2;
    }

    /* ---- build the job descriptor list ---- */
    static jobdesc_t J[MAX_JOBS];
    int nj = 0;

    /* directed standalone corner cases */
    #define ADD(_K,_ac,_ck,_ty) do{ J[nj].K=(_K); J[nj].accum=(_ac); \
                                     J[nj].check=(_ck); J[nj].type=(_ty); nj++; }while(0)
    ADD(1,        0,1,T_RANDOM);          /* K = 1                      */
    ADD(2,        0,1,T_RANDOM);          /* K = 2                      */
    ADD(g_n,      0,1,T_IDENTITY);        /* identity -> C == B tile    */
    ADD(g_kmax,   0,1,T_RANDOM);          /* K = KMAX (largest single)  */
    ADD(g_kmax,   0,1,T_MAXPOS);          /* max positive saturation    */
    ADD(g_kmax,   0,1,T_MAXNEG);          /* large negative sums        */
    ADD(g_kmax,   0,1,T_MIX);             /* mixed-sign extreme         */
    ADD(16,       0,1,T_ZERO_A);          /* zero A  -> C = 0           */
    ADD(16,       0,1,T_ZERO_B);          /* zero B  -> C = 0           */
    ADD(g_kmax,   0,1,T_ONELANE);         /* only k=0 contributes       */

    /* accumulate chain 1: four KMAX runs -> effective K = 4*KMAX on one tile */
    ADD(g_kmax,0,0,T_CHAIN); ADD(g_kmax,1,0,T_CHAIN);
    ADD(g_kmax,1,0,T_CHAIN); ADD(g_kmax,1,1,T_CHAIN);
    /* accumulate chain 2: uneven chunks */
    ADD(g_kmax,0,0,T_CHAIN); ADD(g_kmax/2,1,0,T_CHAIN); ADD(7,1,1,T_CHAIN);

    /* random standalone jobs */
    for (int r = 0; r < nrand && nj < MAX_JOBS; r++) {
        int K = 1 + (int)(xrand() % (uint64_t)g_kmax);
        ADD(K, 0, 1, T_RANDOM);
    }
    #undef ADD

    /* ---- device + running golden accumulator ---- */
    gemm_shape_t shape = { g_n, g_dw, g_aw, g_kmax };
    gemm_device_t *dev = gemm_dev_create(&shape);
    if (!dev) { fprintf(stderr, "dev create failed\n"); return 2; }

    static int8_t  A[MAX_BYTES], B[MAX_BYTES], a_col[MAX_BYTES];
    static int32_t gold[MAX_N*MAX_N], c_hw[MAX_N*MAX_N];

    char path[512];
    snprintf(path, sizeof path, "%s/jobs.txt", outdir);
    FILE *mf = fopen(path, "w"); if (!mf) { perror(path); return 2; }
    /* header: NJOBS N DATA_WIDTH ACC_WIDTH KMAX  then "idx K accum check" lines */
    fprintf(mf, "%d %d %d %d %d\n", nj, g_n, g_dw, g_aw, g_kmax);

    long total_macs = 0, total_checks = 0;
    for (int j = 0; j < nj; j++) {
        int K = J[j].K, accum = J[j].accum;
        fill_job(J[j].type, K, A, B);

        /* golden: clear or accumulate this tile product onto the running C */
        gemm_tile_ref(A, B, g_n, K, accum, gold);

        /* column-major A^T for the driver / hardware */
        for (int k=0;k<K;k++) for (int i=0;i<g_n;i++) a_col[k*g_n+i] = A[i*K+k];

        int rc = gemm_run_tile(dev, a_col, B, K, accum, J[j].check ? c_hw : NULL);
        if (rc != 0) { fprintf(stderr, "driver job %d rc=%d\n", j, rc); return 3; }
        if (J[j].check)
            for (int e=0;e<g_n*g_n;e++)
                if (c_hw[e] != gold[e]) {
                    fprintf(stderr, "driver/golden mismatch job %d elem %d: %d vs %d\n",
                            j, e, c_hw[e], gold[e]);
                    return 3;
                }

        snprintf(path, sizeof path, "%s/a_%03d.hex", outdir, j); write_a_hex(path, A, K);
        snprintf(path, sizeof path, "%s/b_%03d.hex", outdir, j); write_b_hex(path, B, K);
        snprintf(path, sizeof path, "%s/c_%03d.hex", outdir, j); write_c_hex(path, gold);

        fprintf(mf, "%d %d %d %d\n", j, K, accum, J[j].check);
        total_macs   += (long)g_n * g_n * K;
        if (J[j].check) total_checks += (long)g_n * g_n;
    }
    fclose(mf);

    /* ---- high-level tiled GEMM self-check (non-tile-aligned sizes) ---- */
    {
        int M = 20, Kc = 40, P = 12;         /* none a multiple of n=8 */
        static int8_t  Af[20*40], Bf[40*12];
        static int32_t Chw[20*12], Cref[20*12];
        for (int i=0;i<M*Kc;i++) Af[i]=rand_i8();
        for (int i=0;i<Kc*P;i++) Bf[i]=rand_i8();
        gemm_ref_full(Af, Bf, M, Kc, P, Cref);
        int rc = gemm_matmul(dev, Af, Bf, M, Kc, P, Chw);
        if (rc != 0) { fprintf(stderr, "gemm_matmul rc=%d\n", rc); return 3; }
        for (int i=0;i<M*P;i++)
            if (Chw[i] != Cref[i]) {
                fprintf(stderr, "tiled gemm mismatch at %d: %d vs %d\n", i, Chw[i], Cref[i]);
                return 3;
            }
        printf("[host] tiled gemm_matmul %dx%dx%d matched reference\n", M, Kc, P);
    }

    /* ---- software-only baseline timing (scalar reference, many repeats) ---- */
    static int8_t  Ab[MAX_N*MAX_KMAX], Bb[MAX_KMAX*MAX_N];
    static int32_t Cb[MAX_N*MAX_N];
    for (int i=0;i<g_n*g_kmax;i++) Ab[i]=rand_i8();
    for (int i=0;i<g_kmax*g_n;i++) Bb[i]=rand_i8();
    long macs_per_iter = (long)g_n*g_n*g_kmax;
    int repeats = (int)(200000000L / (macs_per_iter + 1)) + 1;   /* ~2e8 MACs */
    volatile int64_t sink = 0;
    clock_t t0 = clock();
    for (int r=0;r<repeats;r++) { gemm_tile_ref(Ab, Bb, g_n, g_kmax, 0, Cb); sink += Cb[0]; }
    clock_t t1 = clock();
    (void)sink;
    double secs = (double)(t1 - t0) / (double)CLOCKS_PER_SEC;
    double ns_per_mac = secs > 0 ? (secs*1e9) / ((double)macs_per_iter*repeats) : 0.0;

    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir);
    FILE *sm = fopen(path, "w");
    if (sm) {
        fprintf(sm, "total_jobs %d\n", nj);
        fprintf(sm, "total_tile_macs %ld\n", total_macs);
        fprintf(sm, "total_output_checks %ld\n", total_checks);
        fprintf(sm, "sw_model_cycles %ld\n", total_macs);   /* ideal scalar 1 MAC/cycle */
        fprintf(sm, "sw_host_ns_per_mac %.5f\n", ns_per_mac);
        fprintf(sm, "sw_repeats %d\n", repeats);
        fclose(sm);
    }

    printf("[host] generated %d jobs, %ld tile-MACs, %ld checked outputs into %s\n",
           nj, total_macs, total_checks, outdir);
    printf("[host] driver model matched golden on every checked job\n");
    printf("[host] software baseline: %.5f ns/MAC on host (%d repeats)\n", ns_per_mac, repeats);

    gemm_dev_destroy(dev);
    return 0;
}
