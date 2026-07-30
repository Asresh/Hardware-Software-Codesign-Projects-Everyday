/* ----------------------------------------------------------------------------
 * fir_host.c
 * Host application for the FIR accelerator. It:
 *   1. builds a batch of jobs (random + directed corner cases),
 *   2. computes the golden output for each with the software reference,
 *   3. exercises the firmware driver against the device model and checks it
 *      matches the golden (a software-side self-test of the driver),
 *   4. writes the stimulus/golden as $readmemh-friendly hex plus a manifest for
 *      the SystemVerilog testbench, and
 *   5. measures the software-only baseline used for the hardware speedup.
 *
 * Usage:
 *   fir_host --taps T --data-width D --coef-width C --acc-width A \
 *            --fifo-depth F --njobs N --max-len L --seed S --outdir DIR
 * ------------------------------------------------------------------------- */
#include "fir_accel.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_TAPS 64
#define MAX_LEN  2048
#define MAX_JOBS 256
#define DIRECTED_JOBS 12   /* headroom reserved for the directed corner cases */

/* Stall directives interpreted by the testbench (do not affect the golden).
 * STALL_LONGOUT holds the consumer off long enough to fill the output FIFO and
 * back-pressure the input port (deasserting s_axis_tready). */
enum { STALL_NONE = 0, STALL_IN = 1, STALL_OUT = 2, STALL_BOTH = 3, STALL_LONGOUT = 4 };

typedef struct {
    int     len;
    int     stall_mode;
    int64_t coef[MAX_TAPS];
    int64_t x[MAX_LEN];
    int64_t y[MAX_LEN];
} job_t;

static int g_taps, g_dw, g_cw, g_aw, g_fifo;

/* 64-bit RNG (xorshift) seeded deterministically so runs are reproducible. */
static uint64_t g_state;
static uint64_t xrand(void)
{
    uint64_t x = g_state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    return (g_state = x);
}
static int64_t rand_signed(int width)
{
    return fir_sign_extend(xrand(), width);
}

static int64_t max_pos(int width) { return (int64_t)(((uint64_t)1 << (width - 1)) - 1u); }
static int64_t min_neg(int width) { return -(int64_t)((uint64_t)1 << (width - 1)); }

static void fill_random(job_t *j, int len)
{
    j->len = len;
    for (int k = 0; k < g_taps; k++) j->coef[k] = rand_signed(g_cw);
    for (int n = 0; n < len; n++)    j->x[n]    = rand_signed(g_dw);
}

/* ---- vector file writers (fixed-width two's-complement hex, one per line) ---- */
static int hexdigits(int width) { return (width + 3) / 4; }

static void write_hex(const char *path, const int64_t *v, int n, int width)
{
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(2); }
    int nd = hexdigits(width);
    for (int i = 0; i < n; i++)
        fprintf(f, "%0*llx\n", nd, (unsigned long long)fir_mask_bits(v[i], width));
    fclose(f);
}

int main(int argc, char **argv)
{
    int njobs = 24, max_len = 48;
    unsigned long seed = 1;
    const char *outdir = "tb/vectors";
    g_taps = 8; g_dw = 16; g_cw = 16; g_fifo = 16; g_aw = 0;

    for (int i = 1; i < argc - 1; i++) {
        if      (!strcmp(argv[i], "--taps"))        g_taps  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--data-width"))  g_dw    = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--coef-width"))  g_cw    = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--acc-width"))   g_aw    = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fifo-depth"))  g_fifo  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--njobs"))       njobs   = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--max-len"))     max_len = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed"))        seed    = strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--outdir"))      outdir  = argv[++i];
    }
    g_state = seed ? seed : 0x9E3779B97F4A7C15ull;

    /* ceil(log2(taps)) */
    int lg = 0; while ((1 << lg) < g_taps) lg++;
    if (g_aw == 0) g_aw = g_dw + g_cw + lg;

    if (g_taps < 1 || g_taps > MAX_TAPS || max_len < 1 || max_len > MAX_LEN ||
        g_dw < 2 || g_dw > 63 || g_cw < 2 || g_cw > 32 || njobs < 0) {
        fprintf(stderr, "parameters out of range "
                "(taps 1..%d, max-len 1..%d, data-width 2..63, coef-width 2..32, njobs >= 0)\n",
                MAX_TAPS, MAX_LEN);
        return 2;
    }
    if (njobs > MAX_JOBS - DIRECTED_JOBS) {
        fprintf(stderr, "note: njobs capped at %d to leave room for directed corner cases\n",
                MAX_JOBS - DIRECTED_JOBS);
        njobs = MAX_JOBS - DIRECTED_JOBS;
    }

    fir_shape_t shape = { g_taps, g_dw, g_cw, g_aw };
    fir_device_t *dev = fir_dev_create(&shape, g_fifo);
    if (!dev) { fprintf(stderr, "alloc failed\n"); return 2; }

    static job_t jobs[MAX_JOBS];
    int nj = 0;

    /* ---- randomized jobs ---- */
    for (int j = 0; j < njobs && nj < MAX_JOBS - DIRECTED_JOBS; j++) {
        int len = 1 + (int)(xrand() % (uint64_t)max_len);
        fill_random(&jobs[nj], len);
        jobs[nj].stall_mode = (int)(xrand() % 4);
        nj++;
    }

    /* ---- directed corner cases (bounded: never exceed the jobs[] array) ---- */
    if (nj + DIRECTED_JOBS > MAX_JOBS) { fprintf(stderr, "too many jobs\n"); return 2; }
    #define ADD_JOB(_len,_stall) (jobs[nj].len=(_len), jobs[nj].stall_mode=(_stall), &jobs[nj])
    {
        job_t *c;
        /* all-zero input (random coefs already implied; set explicit zeros) */
        c = ADD_JOB(20, STALL_BOTH);
        for (int k=0;k<g_taps;k++) c->coef[k]=rand_signed(g_cw);
        for (int n=0;n<c->len;n++) c->x[n]=0; nj++;

        /* impulse: single max-positive sample -> outputs are the coefficients */
        c = ADD_JOB(g_taps+4, STALL_NONE);
        for (int k=0;k<g_taps;k++) c->coef[k]=rand_signed(g_cw);
        for (int n=0;n<c->len;n++) c->x[n]=0; c->x[0]=max_pos(g_dw); nj++;

        /* positive saturation: max coef * max data on every tap */
        c = ADD_JOB(g_taps+2, STALL_OUT);
        for (int k=0;k<g_taps;k++) c->coef[k]=max_pos(g_cw);
        for (int n=0;n<c->len;n++) c->x[n]=max_pos(g_dw); nj++;

        /* negative extreme: max coef * min data */
        c = ADD_JOB(g_taps+2, STALL_IN);
        for (int k=0;k<g_taps;k++) c->coef[k]=max_pos(g_cw);
        for (int n=0;n<c->len;n++) c->x[n]=min_neg(g_dw); nj++;

        /* mixed-sign extreme */
        c = ADD_JOB(g_taps+2, STALL_BOTH);
        for (int k=0;k<g_taps;k++) c->coef[k]=(k&1)?min_neg(g_cw):max_pos(g_cw);
        for (int n=0;n<c->len;n++) c->x[n]=(n&1)?max_pos(g_dw):min_neg(g_dw); nj++;

        /* length 1 */
        c = ADD_JOB(1, STALL_NONE);
        for (int k=0;k<g_taps;k++) c->coef[k]=rand_signed(g_cw);
        c->x[0]=rand_signed(g_dw); nj++;

        /* length == FIFO depth (input FIFO exactly full if drained slowly) */
        c = ADD_JOB(g_fifo, STALL_OUT);
        for (int k=0;k<g_taps;k++) c->coef[k]=rand_signed(g_cw);
        for (int n=0;n<c->len;n++) c->x[n]=rand_signed(g_dw); nj++;

        /* length > FIFO depth (forces refill / sustained backpressure) */
        c = ADD_JOB(g_fifo*3, STALL_BOTH);
        for (int k=0;k<g_taps;k++) c->coef[k]=rand_signed(g_cw);
        for (int n=0;n<c->len;n++) c->x[n]=rand_signed(g_dw); nj++;

        /* large back-to-back job: amortizes per-job setup so the measured
         * throughput approaches the steady-state 1 sample/clock. */
        int big = 512; if (big > MAX_LEN) big = MAX_LEN;
        c = ADD_JOB(big, STALL_NONE);
        for (int k=0;k<g_taps;k++) c->coef[k]=rand_signed(g_cw);
        for (int n=0;n<c->len;n++) c->x[n]=rand_signed(g_dw); nj++;

        /* long consumer stall, NO input gaps: fills the output FIFO, stalls the
         * datapath, and back-pressures the input port (s_axis_tready deasserts).
         * This is the job that actually exercises end-to-end backpressure. */
        c = ADD_JOB(g_fifo*4, STALL_LONGOUT);
        for (int k=0;k<g_taps;k++) c->coef[k]=rand_signed(g_cw);
        for (int n=0;n<c->len;n++) c->x[n]=rand_signed(g_dw); nj++;
    }
    #undef ADD_JOB

    /* ---- golden + driver self-check + vector emission ---- */
    long total_samples = 0, total_macs = 0;
    char path[512];
    FILE *mf = fopen(
        (snprintf(path, sizeof path, "%s/jobs.txt", outdir), path), "w");
    if (!mf) { perror(path); return 2; }
    /* Line 1 (numeric, easy to $fscanf from the testbench):
     *   NJOBS TAPS DATA_WIDTH COEF_WIDTH ACC_WIDTH FIFO_DEPTH
     * Then one "<index> <len> <stall_mode>" line per job. */
    fprintf(mf, "%d %d %d %d %d %d\n", nj, g_taps, g_dw, g_cw, g_aw, g_fifo);

    for (int j = 0; j < nj; j++) {
        job_t *J = &jobs[j];
        fir_ref(J->coef, g_taps, J->x, J->len, J->y);

        /* Drive the firmware path against the device model and confirm match. */
        static int64_t drv[MAX_LEN];
        fir_reset(dev);
        if (fir_load_coefs(dev, J->coef, g_taps) != 0) { fprintf(stderr,"coef load fail\n"); return 3; }
        int rc = fir_run_job(dev, J->x, J->len, drv);
        if (rc != 0) { fprintf(stderr, "driver job %d rc=%d\n", j, rc); return 3; }
        for (int n = 0; n < J->len; n++)
            if (drv[n] != J->y[n]) {
                fprintf(stderr, "driver/golden mismatch job %d idx %d: %lld vs %lld\n",
                        j, n, (long long)drv[n], (long long)J->y[n]);
                return 3;
            }

        snprintf(path, sizeof path, "%s/coef_%03d.hex", outdir, j);
        write_hex(path, J->coef, g_taps, g_cw);
        snprintf(path, sizeof path, "%s/in_%03d.hex", outdir, j);
        write_hex(path, J->x, J->len, g_dw);
        snprintf(path, sizeof path, "%s/gold_%03d.hex", outdir, j);
        write_hex(path, J->y, J->len, g_aw);

        fprintf(mf, "%d %d %d\n", j, J->len, J->stall_mode);
        total_samples += J->len;
        total_macs    += (long)J->len * g_taps;
    }
    fclose(mf);

    /* ---- software-only baseline timing (many repeats for a stable number) ---- */
    int repeats = 2000;
    if (total_samples > 0) {
        long target = 4000000L;                         /* ~4M sample-ops total */
        repeats = (int)(target / (total_samples + 1)) + 1;
    }
    volatile int64_t sink = 0;
    static int64_t tmp[MAX_LEN];
    clock_t t0 = clock();
    for (int r = 0; r < repeats; r++)
        for (int j = 0; j < nj; j++) {
            fir_ref(jobs[j].coef, g_taps, jobs[j].x, jobs[j].len, tmp);
            sink += tmp[jobs[j].len ? jobs[j].len - 1 : 0];
        }
    clock_t t1 = clock();
    (void)sink;
    double secs = (double)(t1 - t0) / (double)CLOCKS_PER_SEC;
    double ns_per_sample = secs > 0 ? (secs * 1e9) / ((double)total_samples * repeats) : 0.0;

    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir);
    FILE *sm = fopen(path, "w");
    if (sm) {
        fprintf(sm, "total_jobs %d\n", nj);
        fprintf(sm, "total_samples %ld\n", total_samples);
        fprintf(sm, "total_macs %ld\n", total_macs);
        fprintf(sm, "sw_model_cycles %ld\n", total_macs);   /* ideal scalar 1 MAC/cycle */
        fprintf(sm, "sw_host_ns_per_sample %.3f\n", ns_per_sample);
        fprintf(sm, "sw_repeats %d\n", repeats);
        fclose(sm);
    }

    printf("[host] generated %d jobs, %ld samples, %ld MACs into %s\n",
           nj, total_samples, total_macs, outdir);
    printf("[host] driver model matched golden on every job\n");
    printf("[host] software baseline: %.3f ns/sample on host, model %ld scalar cycles\n",
           ns_per_sample, total_macs);

    fir_dev_destroy(dev);
    return 0;
}
