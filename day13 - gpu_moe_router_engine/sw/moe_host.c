/* ============================================================================
 * moe_host.c - stimulus generator + golden producer for the MoE router.
 *
 *   ./moe_host --nrand N --seed S --outdir DIR --cap C
 *
 * Writes, into DIR:
 *   tokens.hex     one 128-bit ingress beat per token (E packed Q8.8 logits)
 *   golden.txt     the bit-exact dispatch record per token (from moe_ref.c)
 *   exp_lut.hex    the shared exp LUT the RTL loads via $readmemh
 *   moe_const.vh   Verilog params (token count, E, K, cap, seed)
 *   sw_metrics.txt scalar-baseline cost-model numbers for the metrics report
 *
 * The directed corner cases run first (ties, one dominant expert, monotone
 * ramps, deep negatives that clip exp, a capacity storm), then N random
 * tokens.  The golden stream is produced by replaying the whole sequence
 * through the reference router so its capacity state matches the hardware.
 * ==========================================================================*/
#include "moe.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXT 4096

static uint64_t rng_state;
static uint64_t xrng(void) {           /* SplitMix64-style deterministic PRNG */
    uint64_t z = (rng_state += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}
static int rand_logit(int lo, int hi) {         /* inclusive Q8.8 range        */
    return lo + (int)(xrng() % (uint64_t)(hi - lo + 1));
}

static int16_t toks[MAXT][MOE_E];
static int     ntok = 0;

static void push(const int16_t *l) {
    int i;
    if (ntok >= MAXT) return;
    for (i = 0; i < MOE_E; i++) toks[ntok][i] = l[i];
    ntok++;
}

int main(int argc, char **argv)
{
    int    nrand = 300;
    uint64_t seed = 0x0D13C0DEC0DE0D13ull;
    uint32_t cap = 24;
    const char *outdir = "tb/vectors";
    int i, k, t;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--nrand") && i + 1 < argc) nrand = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--cap") && i + 1 < argc) cap = (uint32_t)strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--outdir") && i + 1 < argc) outdir = argv[++i];
    }
    rng_state = seed;

    /* -------------------- directed corner cases ----------------------------*/
    /* IX() clamps a hand-picked expert index into range so the directed cases
       stay valid at any expert count E >= 2. */
    #define IX(x) ((x) < MOE_E ? (x) : (MOE_E - 1))
    int16_t l[MOE_E];
    /* 1: all equal -> ties, lowest indices win */
    for (i = 0; i < MOE_E; i++) l[i] = 256; push(l);
    /* 2: one dominant expert */
    for (i = 0; i < MOE_E; i++) l[i] = -512; l[IX(3)] = 2000; push(l);
    /* 3: two clearly-top experts, close weights */
    for (i = 0; i < MOE_E; i++) l[i] = -800; l[IX(1)] = 300; l[IX(6)] = 296; push(l);
    /* 4: monotone increasing ramp -> top = last two */
    for (i = 0; i < MOE_E; i++) l[i] = (int16_t)(-1024 + i * 200); push(l);
    /* 5: monotone decreasing ramp -> top = first two */
    for (i = 0; i < MOE_E; i++) l[i] = (int16_t)(1024 - i * 200); push(l);
    /* 6: max at index 0 and last, tie handling */
    for (i = 0; i < MOE_E; i++) l[i] = -300; l[0] = 900; l[MOE_E-1] = 900; push(l);
    /* 7: deep-negative spread -> second exp clips to ~0 */
    for (i = 0; i < MOE_E; i++) l[i] = -4096; l[IX(2)] = 3000; l[IX(5)] = -100; push(l);
    /* 8: all strongly negative but ordered */
    for (i = 0; i < MOE_E; i++) l[i] = (int16_t)(-2000 - i * 50); push(l);
    /* 9-16: capacity storm - eight tokens hammering experts 0 and 1 */
    for (t = 0; t < 8; t++) {
        for (i = 0; i < MOE_E; i++) l[i] = -700;
        l[0] = 1500; l[IX(1)] = 1400; push(l);
    }

    int directed = ntok;

    /* -------------------- random tokens ------------------------------------*/
    for (t = 0; t < nrand; t++) {
        for (i = 0; i < MOE_E; i++) l[i] = (int16_t)rand_logit(-2200, 2200);
        /* occasionally inject an extreme outlier to exercise exp clipping    */
        if ((xrng() & 7) == 0) l[xrng() % MOE_E] = (int16_t)rand_logit(3000, 8000);
        push(l);
    }

    /* -------------------- build LUT + golden -------------------------------*/
    uint32_t lut[MOE_LUT_N];
    moe_build_lut(lut);

    moe_state_t st;
    memset(&st, 0, sizeof(st));
    st.cap = cap;

    char path[512];
    snprintf(path, sizeof(path), "%s/golden.txt", outdir);
    FILE *fg = fopen(path, "w");
    if (!fg) { perror("golden"); return 1; }

    uint64_t tot_routed = 0, tot_ovf = 0;
    double   max_abs_err = 0.0;      /* fixed-point gate weight vs double softmax */
    for (t = 0; t < ntok; t++) {
        moe_record_t r;

        /* ---- accuracy probe: compare pre-capacity fixed weights to the
         *      double-precision top-K softmax of the same logits ---------- */
        int sel[MOE_K], taken[MOE_E];
        for (i = 0; i < MOE_E; i++) taken[i] = 0;
        for (k = 0; k < MOE_K; k++) {
            int best = -1;
            for (i = 0; i < MOE_E; i++) {
                if (taken[i]) continue;
                if (best < 0 || toks[t][i] > toks[t][best]) best = i;
            }
            sel[k] = best; taken[best] = 1;
        }
        int16_t mx = toks[t][sel[0]];
        double dsum = 0.0; uint32_t fden = 0; uint32_t fexp[MOE_K];
        for (k = 0; k < MOE_K; k++) {
            double dd = ((double)toks[t][sel[k]] - (double)mx) / 256.0; /* Q8.8->real */
            dsum += exp(dd);
            fexp[k] = moe_exp_q16((int32_t)toks[t][sel[k]] - (int32_t)mx, lut);
            fden += fexp[k];
        }
        for (k = 0; k < MOE_K; k++) {
            double dw = exp(((double)toks[t][sel[k]] - (double)mx) / 256.0) / dsum;
            double fw = (double)moe_gate_q16(fexp[k], fden) / 65536.0;
            double e = fw - dw; if (e < 0) e = -e;
            if (e > max_abs_err) max_abs_err = e;
        }

        moe_route(&st, toks[t], (uint16_t)t, lut, &r);
        fprintf(fg, "%d", r.token_id);
        for (k = 0; k < MOE_K; k++)
            fprintf(fg, " %u %u %u", r.expert[k], r.weight[k], r.overflow[k]);
        fprintf(fg, " %u\n", r.routed);
        tot_routed += r.routed;
    }
    tot_ovf = st.overflows;
    fclose(fg);

    /* -------------------- tokens.hex (128-bit beats) -----------------------*/
    snprintf(path, sizeof(path), "%s/tokens.hex", outdir);
    FILE *ft = fopen(path, "w");
    for (t = 0; t < ntok; t++) {
        for (i = MOE_E - 1; i >= 0; i--)
            fprintf(ft, "%04x", (uint16_t)toks[t][i]);
        fprintf(ft, "\n");
    }
    fclose(ft);

    /* -------------------- exp_lut.hex --------------------------------------*/
    snprintf(path, sizeof(path), "%s/exp_lut.hex", outdir);
    FILE *fl = fopen(path, "w");
    for (i = 0; i < MOE_LUT_N; i++) fprintf(fl, "%05x\n", lut[i]);
    fclose(fl);

    /* -------------------- moe_const.vh -------------------------------------*/
    snprintf(path, sizeof(path), "%s/moe_const.vh", outdir);
    FILE *fc = fopen(path, "w");
    fprintf(fc, "`define NUM_TOKENS %d\n", ntok);
    fprintf(fc, "`define NUM_DIRECTED %d\n", directed);
    fprintf(fc, "`define CFG_E %d\n", MOE_E);
    fprintf(fc, "`define CFG_K %d\n", MOE_K);
    fprintf(fc, "`define CFG_CAP %u\n", cap);
    fprintf(fc, "`define CFG_SEED 64'h%016llx\n", (unsigned long long)seed);
    fclose(fc);

    /* -------------------- sw_metrics.txt -----------------------------------*/
    long per = moe_baseline_cycles_per_token();
    snprintf(path, sizeof(path), "%s/sw_metrics.txt", outdir);
    FILE *fm = fopen(path, "w");
    fprintf(fm, "baseline_cycles_per_token %ld\n", per);
    fprintf(fm, "baseline_total_cycles %ld\n", per * (long)ntok);
    fprintf(fm, "num_tokens %d\n", ntok);
    fprintf(fm, "num_directed %d\n", directed);
    fprintf(fm, "num_routed %llu\n", (unsigned long long)tot_routed);
    fprintf(fm, "num_overflow %llu\n", (unsigned long long)tot_ovf);
    fprintf(fm, "max_abs_weight_err %.8f\n", max_abs_err);
    fclose(fm);

    printf("moe_host: %d tokens (%d directed + %d random), cap=%u, "
           "routed=%llu overflow=%llu -> %s\n",
           ntok, directed, nrand, cap,
           (unsigned long long)tot_routed, (unsigned long long)tot_ovf, outdir);
    return 0;
}
