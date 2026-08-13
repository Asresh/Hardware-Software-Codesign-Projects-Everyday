/* ===========================================================================
 * mxq_host.c - builds the experiment.
 *
 * Assembles the kernels, generates the data, runs everything through the
 * instruction-set simulator, and writes out what the testbench needs: the
 * program images, the memory initialisation, the expected memory, the commit
 * trace and the expected value of every counter.
 *
 * Before it emits a single vector it checks itself: the register-map fold
 * against the header, the round-to-even rule against the table it replaced,
 * and the whole fixed-point cast against an independent floating-point one
 * over all 65536 bf16 values at eleven scales.  A generator that is wrong in
 * the same way as the hardware proves nothing, so this is where the
 * independence has to be established - not in the testbench.
 * ===========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "mxq.h"

#define MAX_IMG    4096
#define MAX_JOBS   1200
#define JOBW       32
#define GUARD      16
#define IN_BASE_W  16
#define TRACE_CAP  600000

enum { K_QC = 0, K_QB, K_DC, K_DB, K_ISA, K_TRAP };

static uint32_t img_qc[MAX_IMG], img_qb[MAX_IMG];
static uint32_t img_dc[MAX_IMG], img_db[MAX_IMG];
static uint32_t img_isa[MAX_IMG], img_trap[MXQ_TRAP_N][MAX_IMG];
static int      n_qc, n_qb, n_dc, n_db, n_isa, n_trap[MXQ_TRAP_N];

static uint32_t jobs[MAX_JOBS][JOBW];
static int      njobs;

static uint32_t *imem_pool;   static long imem_n, imem_cap;
static uint32_t *dinit_pool;  static long dinit_n, dinit_cap;   /* addr,val */
static uint32_t *dexp_pool;   static long dexp_n, dexp_cap;     /* addr,val */
static uint32_t *trace_pool;  static long trace_n, trace_cap;   /* 5 words  */

static uint32_t dmem[MXQ_DMEM_WORDS], dmem0[MXQ_DMEM_WORDS];
static uint32_t imem_full[MXQ_IMEM_WORDS];
static mxq_commit_t trace_buf[200000];

/* ---- totals reported to the metrics extractor --------------------------- */
static uint64_t tot_cycles[6], tot_instret[6], tot_custom[6], tot_blocks[6];
static uint64_t tot_elems[6], tot_jobs[6];

/* totals over the data where both versions of a kernel ran, which is the only
 * comparison that means anything */
static uint64_t pair_cyc[4], pair_ins[4], pair_blocks;
static uint64_t host_checks;
static uint64_t last_cycles, last_instret;

/* ------------------------------------------------------------------------ */
static uint64_t rng_s = 0x2B21C0FFEEULL;
static uint32_t rnd(void)
{
    rng_s ^= rng_s << 13; rng_s ^= rng_s >> 7; rng_s ^= rng_s << 17;
    return (uint32_t)(rng_s >> 16);
}
static uint32_t rnd_n(uint32_t n) { return n ? rnd() % n : 0; }

static void *grow(void *p, long *cap, long need, size_t esz)
{
    if (need <= *cap) return p;
    while (*cap < need) *cap = *cap ? *cap * 2 : 4096;
    p = realloc(p, (size_t)*cap * esz);
    if (!p) { fprintf(stderr, "out of memory\n"); exit(1); }
    return p;
}

static uint16_t bf16(uint32_t s, uint32_t e, uint32_t m)
{
    return (uint16_t)((s << 15) | ((e & 0xFFu) << 7) | (m & 0x7Fu));
}

/* ===========================================================================
 * self-checks
 * ===========================================================================*/
static void self_check(void)
{
    static const uint8_t scales[] = { 0, 1, 2, 64, 120, 126, 127, 128, 130,
                                      200, 254 };
    uint32_t v;
    int k, bad = 0;

    if (mxq_regmap_csum() != MXQ_REGMAP_CSUM) {
        fprintf(stderr, "regmap checksum: computed %08X, header %08X\n",
                mxq_regmap_csum(), (uint32_t)MXQ_REGMAP_CSUM);
        exit(1);
    }

    /* the parity form of round-to-nearest-even against the explicit table */
    for (uint32_t u = 0; u < 4096u && !bad; u++) {
        for (int st = 0; st < 2; st++) {
            uint32_t us = u + (uint32_t)st, c1 = 0, c2 = 0;
            for (k = 0; k < MXQ_NTHRESH; k++)
                c1 += (k & 1) ? (u >= MXQ_THRESH[k]) : (us > MXQ_THRESH[k]);
            for (k = 0; k < MXQ_NTHRESH; k++) if (u >  MXQ_THRESH[k]) c2 = (uint32_t)k + 1u;
            for (k = 0; k < MXQ_NTHRESH; k++)
                if (u == MXQ_THRESH[k]) c2 = st ? (uint32_t)k + 1u : MXQ_RNE_EVEN[k];
            if (c1 != c2) {
                fprintf(stderr, "RNE rule mismatch at u=%u sticky=%d: %u vs %u\n",
                        u, st, c1, c2);
                bad = 1; break;
            }
        }
    }
    if (bad) exit(1);

    /* the fixed-point cast against the floating-point one, exhaustively */
    for (v = 0; v < 65536u; v++) {
        for (k = 0; k < (int)(sizeof scales); k++) {
            uint8_t a = mxq_quant_elem((uint16_t)v, scales[k]);
            uint8_t b = mxq_quant_elem_fp((uint16_t)v, scales[k]);
            if (a != b) {
                fprintf(stderr, "cast mismatch: bf16 %04X scale %u -> "
                        "fixed %u, float %u\n", v, scales[k], a, b);
                exit(1);
            }
        }
    }

    /* dequantisation against the same floating-point grid, over the range
     * where no clamping is involved - the clamped edges are directed cases in
     * the testbench instead */
    for (uint32_t c = 0; c < 16u; c++) {
        for (k = 0; k < (int)(sizeof scales); k++) {
            static const int eoff[8] = { 0, -1, 0, 0, 1, 1, 2, 2 };
            int e = (int)scales[k] + eoff[c & 7u];
            uint16_t got;
            double   ref, val;
            if ((c & 7u) == 0u || e < 1 || e > 254) continue;
            got = mxq_dequant_elem((uint8_t)c, scales[k]);
            ref = mxq_dequant_value((uint8_t)c, scales[k]);
            val = ldexp(1.0 + (double)(got & 0x7Fu) / 128.0,
                        (int)((got >> 7) & 0xFFu) - 127);
            if (got & 0x8000u) val = -val;
            if (val != ref) {
                fprintf(stderr, "dequant mismatch: code %u scale %u\n",
                        c, scales[k]);
                exit(1);
            }
        }
    }

    printf("self-check: regmap fold, rounding rule, and the whole cast at "
           "11 scales x 65536 values agree\n");
}

/* ===========================================================================
 * data generators
 * ===========================================================================*/
/* ties: an amax of 2^130 fixes the shared scale at 128, and each of the seven
 * midpoints is then reachable exactly by one (exponent, mantissa) pair */
static const struct { uint32_t e, m; } TIE[7] = {
    { 126, 0 }, { 127, 64 }, { 128, 32 }, { 128, 96 },
    { 129, 32 }, { 129, 96 }, { 130, 32 }
};

static void gen_directed(int which, uint16_t *v, int n)
{
    int i;
    for (i = 0; i < n; i++) v[i] = 0;
    switch (which) {
    case 0: break;                                        /* all zero        */
    case 1: for (i = 0; i < n; i++) v[i] = bf16(0, 127, 0); break;   /* 1.0  */
    case 2: v[0] = bf16(0, 200, 0);
            for (i = 1; i < n; i++) v[i] = bf16(0, 40, 3); break;
    case 3: v[0] = bf16(0, 254, 127);                     /* max finite      */
            for (i = 1; i < n; i++) v[i] = bf16(i & 1, 252, (uint32_t)i); break;
    case 4:                                               /* every code      */
        v[0] = bf16(0, 130, 0);
        for (i = 1; i < n; i++) {
            static const uint32_t ex[8] = { 0, 126, 127, 127, 128, 128, 129, 129 };
            static const uint32_t ma[8] = { 0, 0, 0, 64, 0, 64, 0, 64 };
            int c = i & 7;
            v[i] = c ? bf16((uint32_t)(i >> 3) & 1u, ex[c], ma[c]) : 0;
        }
        break;
    case 5:                                               /* exact ties      */
        v[0] = bf16(0, 130, 0);
        for (i = 1; i < n; i++)
            v[i] = bf16((uint32_t)i & 1u, TIE[(i - 1) % 7].e, TIE[(i - 1) % 7].m);
        break;
    case 6:                                               /* ties + sticky   */
        v[0] = bf16(0, 130, 0);
        for (i = 1; i < n; i++)
            v[i] = bf16(0, TIE[(i - 1) % 7].e, TIE[(i - 1) % 7].m + 1u);
        break;
    case 7: for (i = 0; i < n; i++) v[i] = 0x8000u; break; /* negative zero  */
    case 8: for (i = 0; i < n; i++)                        /* subnormals     */
                v[i] = bf16((uint32_t)i & 1u, 0, (uint32_t)(i * 7 + 1));
            break;
    case 9: v[0] = bf16(0, 255, 0);                        /* +Inf           */
            for (i = 1; i < n; i++) v[i] = bf16(0, 253, (uint32_t)i * 3u);
            break;
    case 10: v[0] = bf16(1, 255, 64);                      /* NaN            */
             v[1] = bf16(0, 255, 0);
             for (i = 2; i < n; i++) v[i] = bf16(1, 250, (uint32_t)i);
             break;
    case 11: for (i = 0; i < n; i++) v[i] = bf16(1, 127, (uint32_t)i * 3u); break;
    case 12: for (i = 0; i < n; i++)
                 v[i] = bf16((uint32_t)i & 1u, 129, (uint32_t)i * 5u);
             break;
    case 13: for (i = 0; i < n; i++) v[i] = bf16(0, 0, 100); break; /* all sub */
    case 14: for (i = 0; i < n; i++) v[i] = bf16(0, 1, (uint32_t)i); break;
    case 15: for (i = 0; i < n; i++) v[i] = bf16(0, 2, (uint32_t)i * 9u); break;
    case 16: v[0] = bf16(0, 254, 0);                       /* huge spread    */
             for (i = 1; i < n; i++) v[i] = bf16(0, (uint32_t)(2 + i), 0);
             break;
    case 17: for (i = 0; i < n; i++) v[i] = bf16(0, 140, 33); break;
    case 18: for (i = 0; i < n; i++)
                 v[i] = bf16(0, (uint32_t)(120 + (i % 12)), (uint32_t)(i * 4));
             break;
    case 19:                                               /* just below     */
        v[0] = bf16(0, 130, 0);
        for (i = 1; i < n; i++) {
            uint32_t e = TIE[(i - 1) % 7].e, m = TIE[(i - 1) % 7].m;
            v[i] = m ? bf16(0, e, m - 1u) : bf16(0, e - 1u, 126);
        }
        break;
    case 20:                                               /* just above     */
        v[0] = bf16(0, 130, 0);
        for (i = 1; i < n; i++) {
            uint32_t e = TIE[(i - 1) % 7].e, m = TIE[(i - 1) % 7].m;
            v[i] = bf16(0, e, m + 2u);
        }
        break;
    case 21: for (i = 0; i < n; i++) v[i] = bf16(1, 130, 32); break;
    case 22: v[0] = bf16(0, 130, 0);                       /* all code 7     */
             for (i = 1; i < n; i++) v[i] = bf16((uint32_t)i & 1u, 130, 32);
             break;
    default:                                               /* one tie to 0   */
        v[0] = bf16(0, 130, 0);
        for (i = 1; i < n; i++) v[i] = bf16(0, 126, 0);
        break;
    }
}
#define N_DIRECTED 24

static void gen_random(uint16_t *v, int n)
{
    uint32_t centre = 90u + rnd_n(140u);
    uint32_t spread = 1u + rnd_n(12u);
    int i;
    for (i = 0; i < n; i++) {
        uint32_t r = rnd();
        if ((r & 0x1Fu) == 0u) {              /* zeros and specials, sparsely */
            switch ((r >> 5) & 3u) {
            case 0: v[i] = 0; break;
            case 1: v[i] = 0x8000u; break;
            case 2: v[i] = bf16(r >> 7, 0, r >> 8); break;      /* subnormal */
            default: v[i] = bf16(r >> 7, 255, (r >> 8) & 1u ? 0 : 5); break;
            }
        } else {
            uint32_t e = centre + rnd_n(spread * 2u + 1u) - spread;
            if (e < 1u) e = 1u; if (e > 254u) e = 254u;
            v[i] = bf16((r >> 9) & 1u, e, r >> 12);
        }
    }
}

/* ===========================================================================
 * job emission
 * ===========================================================================*/
static long push_imem(const uint32_t *img, int n)
{
    long off = imem_n;
    imem_pool = grow(imem_pool, &imem_cap, imem_n + n, sizeof(uint32_t));
    memcpy(imem_pool + imem_n, img, (size_t)n * sizeof(uint32_t));
    imem_n += n;
    return off;
}

static void push_dinit(uint32_t addr, uint32_t val)
{
    dinit_pool = grow(dinit_pool, &dinit_cap, dinit_n * 2 + 2, sizeof(uint32_t));
    dinit_pool[dinit_n * 2] = addr;
    dinit_pool[dinit_n * 2 + 1] = val;
    dinit_n++;
}

static void push_dexp(uint32_t addr, uint32_t val)
{
    dexp_pool = grow(dexp_pool, &dexp_cap, dexp_n * 2 + 2, sizeof(uint32_t));
    dexp_pool[dexp_n * 2] = addr;
    dexp_pool[dexp_n * 2 + 1] = val;
    dexp_n++;
}

/* Build one job: install the image, initialise memory, run the simulator,
 * record what the hardware must reproduce. */
static void emit_job(int kind, const uint32_t *img, int nimg,
                     const uint32_t *init_addr, const uint32_t *init_val,
                     int ninit, uint32_t a0, uint32_t a1, uint32_t a2,
                     uint32_t a3, uint32_t wdog, int want_trace,
                     int nblk, int blk)
{
    mxq_iss_t s;
    uint32_t *j;
    long dinit_off = dinit_n, dexp_off = dexp_n, trace_off = trace_n;
    long imem_off;
    int i;

    if (njobs >= MAX_JOBS) { fprintf(stderr, "too many jobs\n"); exit(1); }

    imem_off = push_imem(img, nimg);

    memset(dmem, 0, sizeof dmem);
    for (i = 0; i < ninit; i++) {
        dmem[init_addr[i]] = init_val[i];
        push_dinit(init_addr[i], init_val[i]);
    }
    memcpy(dmem0, dmem, sizeof dmem);

    memset(&s, 0, sizeof s);
    s.pc = 0;
    s.trace = trace_buf;
    s.cap_trace = (int)(sizeof trace_buf / sizeof trace_buf[0]);
    s.x[10] = a0; s.x[11] = a1; s.x[12] = a2; s.x[13] = a3;
    /* the simulator sees the whole instruction memory, not just the image:
     * everything past the program is zero, which is an illegal instruction,
     * and the fetch-fault test needs the real end of the RAM to run off */
    memset(imem_full, 0, sizeof imem_full);
    memcpy(imem_full, img, (size_t)nimg * sizeof(uint32_t));
    mxq_iss_run(&s, imem_full, MXQ_IMEM_WORDS, dmem, MXQ_DMEM_WORDS, wdog);

    if (s.ntrace > s.cap_trace) {
        fprintf(stderr, "trace overflow (%d entries)\n", s.ntrace);
        exit(1);
    }

    /* The expectation covers exactly the words the host initialised - the
     * source region, the destination, and a guard band of poison either side
     * of it.  Anything the core wrote outside that set is caught by the full
     * memory sweep at the end of the pass instead, which is the only way to
     * check it: data memory persists across jobs, so a word this job never
     * touched holds whatever the last job left there, not zero. */
    for (i = 0; i < ninit; i++) push_dexp(init_addr[i], dmem[init_addr[i]]);

    if (want_trace && trace_n + s.ntrace <= TRACE_CAP) {
        trace_pool = grow(trace_pool, &trace_cap, (trace_n + s.ntrace) * 5,
                          sizeof(uint32_t));
        for (i = 0; i < s.ntrace; i++) {
            uint32_t *t = trace_pool + (trace_n + i) * 5;
            t[0] = trace_buf[i].pc;    t[1] = trace_buf[i].code;
            t[2] = trace_buf[i].wdata; t[3] = trace_buf[i].addr;
            t[4] = trace_buf[i].sdata;
        }
        trace_n += s.ntrace;
    } else {
        want_trace = 0;
    }

    j = jobs[njobs++];
    memset(j, 0, sizeof jobs[0]);
    j[0]  = (uint32_t)kind;
    j[1]  = (uint32_t)imem_off;   j[2]  = (uint32_t)nimg;
    j[3]  = (uint32_t)dinit_off;  j[4]  = (uint32_t)(dinit_n - dinit_off);
    j[5]  = (uint32_t)dexp_off;   j[6]  = (uint32_t)(dexp_n - dexp_off);
    j[7]  = (uint32_t)trace_off;  j[8]  = want_trace ? (uint32_t)s.ntrace : 0u;
    j[9]  = a0; j[10] = a1; j[11] = a2; j[12] = a3;
    j[13] = 0;                     /* start pc */
    j[14] = wdog;
    j[15] = (uint32_t)s.instret;
    j[16] = (uint32_t)s.cycles;
    j[17] = (uint32_t)s.custom_ops;
    j[18] = (uint32_t)s.branch_taken;
    j[19] = (uint32_t)s.loads;
    j[20] = (uint32_t)s.stores;
    j[21] = s.trapped;
    j[22] = s.errcode;
    j[23] = s.x[10];
    j[24] = s.halt_pc;
    j[25] = s.trap_pc;
    j[26] = (uint32_t)want_trace;
    j[27] = (uint32_t)nblk;
    j[28] = (uint32_t)blk;

    last_cycles  = s.cycles;
    last_instret = s.instret;

    if (kind <= K_DB) {
        tot_cycles[kind]  += s.cycles;
        tot_instret[kind] += s.instret;
        tot_custom[kind]  += s.custom_ops;
        tot_blocks[kind]  += (uint64_t)nblk;
        tot_elems[kind]   += (uint64_t)nblk * (uint64_t)blk;
        tot_jobs[kind]    += 1;
    }
}

/* ---- one cast job over `nblk` blocks of data ---------------------------- */
static uint32_t ia[MXQ_DMEM_WORDS], iv[MXQ_DMEM_WORDS];

static void cast_job(int kind, const uint16_t *data, int nblk, int blk,
                     int want_trace, int paired)
{
    int in_words  = nblk * blk / 2;
    int out_words = nblk * (1 + blk / 8);
    int quant     = (kind == K_QC || kind == K_QB);
    int src_words = quant ? in_words : out_words;
    int dst_words = quant ? out_words : in_words;
    int src_base  = IN_BASE_W;
    int dst_base  = IN_BASE_W + src_words + GUARD;
    int n = 0, b, i;
    const uint32_t *img = (kind == K_QC) ? img_qc : (kind == K_QB) ? img_qb
                        : (kind == K_DC) ? img_dc : img_db;
    int nimg = (kind == K_QC) ? n_qc : (kind == K_QB) ? n_qb
             : (kind == K_DC) ? n_dc : n_db;

    if ((size_t)(dst_base + dst_words + GUARD) >= MXQ_DMEM_WORDS) {
        fprintf(stderr, "job does not fit in data memory\n"); exit(1);
    }

    if (quant) {
        for (i = 0; i < in_words; i++) {
            ia[n] = (uint32_t)(src_base + i);
            iv[n] = (uint32_t)data[2 * i] | ((uint32_t)data[2 * i + 1] << 16);
            n++;
        }
    } else {
        for (b = 0; b < nblk; b++) {
            uint8_t sc, codes[256];
            uint32_t w;
            mxq_quant_block(data + (size_t)b * blk, blk, &sc, codes);
            ia[n] = (uint32_t)(src_base + b * (1 + blk / 8));
            iv[n] = sc; n++;
            for (i = 0; i < blk / 8; i++) {
                w = (uint32_t)codes[i * 4] | ((uint32_t)codes[i * 4 + 1] << 8)
                  | ((uint32_t)codes[i * 4 + 2] << 16)
                  | ((uint32_t)codes[i * 4 + 3] << 24);
                ia[n] = (uint32_t)(src_base + b * (1 + blk / 8) + 1 + i);
                iv[n] = w; n++;
            }
        }
    }
    /* poison the destination and its guard band */
    for (i = -GUARD; i < dst_words + GUARD; i++) {
        ia[n] = (uint32_t)(dst_base + i);
        iv[n] = 0xA5A50000u ^ (uint32_t)(dst_base + i);
        n++;
    }

    emit_job(kind, img, nimg, ia, iv, n,
             (uint32_t)(src_base * 4), (uint32_t)(dst_base * 4),
             (uint32_t)nblk, (uint32_t)blk, 0, want_trace, nblk, blk);

    /* What the kernel left in memory is now checked against sw/mxq_model.c,
     * which knows nothing about RISC-V.  Without this the simulator would be
     * grading its own homework: it would agree with the hardware about every
     * instruction and neither would have to be computing the right cast. */
    for (b = 0; b < nblk; b++) {
        uint8_t sc, codes[256];
        mxq_quant_block(data + (size_t)b * blk, blk, &sc, codes);
        if (quant) {
            uint32_t base = (uint32_t)(dst_base + b * (1 + blk / 8));
            if (dmem[base] != sc) {
                fprintf(stderr, "kernel %d block %d: scale %u, model %u\n",
                        kind, b, dmem[base], sc);
                exit(1);
            }
            host_checks++;
            for (i = 0; i < blk / 8; i++) {
                uint32_t w = (uint32_t)codes[i * 4]
                           | ((uint32_t)codes[i * 4 + 1] << 8)
                           | ((uint32_t)codes[i * 4 + 2] << 16)
                           | ((uint32_t)codes[i * 4 + 3] << 24);
                if (dmem[base + 1 + i] != w) {
                    fprintf(stderr, "kernel %d block %d word %d: %08X vs "
                            "model %08X\n", kind, b, i, dmem[base + 1 + i], w);
                    exit(1);
                }
                host_checks++;
            }
        } else {
            uint16_t ref[256];
            uint32_t base = (uint32_t)(dst_base + b * blk / 2);
            mxq_dequant_block(sc, codes, blk, ref);
            for (i = 0; i < blk / 2; i++) {
                uint32_t w = (uint32_t)ref[2 * i]
                           | ((uint32_t)ref[2 * i + 1] << 16);
                if (dmem[base + i] != w) {
                    fprintf(stderr, "kernel %d block %d word %d: %08X vs "
                            "model %08X\n", kind, b, i, dmem[base + i], w);
                    exit(1);
                }
                host_checks++;
            }
        }
    }

    if (paired) {
        pair_cyc[kind] += last_cycles;
        pair_ins[kind] += last_instret;
    }
}

/* ===========================================================================
 * main
 * ===========================================================================*/
int main(int argc, char **argv)
{
    const char *outdir = ".";
    char path[512];
    FILE *f;
    uint16_t data[64 * 8];
    int i, b, blk = MXQ_BLK, nblk;
    int n_rand = 300, n_rand_base = 30, n_rand_trace = 30;
    long total_commits = 0;

    for (i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--outdir") && i + 1 < argc) outdir = argv[++i];

    self_check();

    n_qc  = mxq_build_quant_custom(img_qc, MAX_IMG);
    n_qb  = mxq_build_quant_base(img_qb, MAX_IMG);
    n_dc  = mxq_build_dequant_custom(img_dc, MAX_IMG);
    n_db  = mxq_build_dequant_base(img_db, MAX_IMG);
    n_isa = mxq_build_isa_test(img_isa, MAX_IMG);
    for (i = 0; i < MXQ_TRAP_N; i++)
        n_trap[i] = mxq_build_trap(img_trap[i], MAX_IMG, i);

    /* ---- 1. ISA conformance ------------------------------------------- */
    {
        int nini = 0;
        for (i = -GUARD; i < MXQ_ISA_SLOTS + GUARD; i++) {
            ia[nini] = (uint32_t)(IN_BASE_W + i);
            iv[nini] = 0xA5A50000u ^ (uint32_t)(IN_BASE_W + i);
            nini++;
        }
        for (i = 0; i < 8; i++) {
            ia[nini] = (uint32_t)(64 + i); iv[nini] = 0x5A5A0000u ^ (uint32_t)i;
            nini++;
        }
        emit_job(K_ISA, img_isa, n_isa, ia, iv, nini,
                 (uint32_t)(IN_BASE_W * 4), 64u * 4u, 0, 0, 0, 1, 0, 0);
        /* the hand-written table, against what the program actually produced */
        for (i = 0; i < MXQ_ISA_SLOTS; i++) {
            if (dmem[IN_BASE_W + i] != MXQ_ISA_EXPECT[i]) {
                fprintf(stderr, "isa slot %d: got %08X, expected %08X\n",
                        i, dmem[IN_BASE_W + i], MXQ_ISA_EXPECT[i]);
                exit(1);
            }
            host_checks++;
        }
        printf("isa conformance: %d hand-written results reproduced\n",
               MXQ_ISA_SLOTS);
    }

    /* ---- 2. traps ------------------------------------------------------- */
    for (i = 0; i < MXQ_TRAP_N; i++) {
        int nini = 0;
        for (b = -GUARD; b < GUARD; b++) {
            ia[nini] = (uint32_t)(IN_BASE_W + b);
            iv[nini] = 0xA5A50000u ^ (uint32_t)(IN_BASE_W + b);
            nini++;
        }
        emit_job(K_TRAP + i, img_trap[i], n_trap[i], ia, iv, nini,
                 (uint32_t)(IN_BASE_W * 4), MXQ_DMEM_WORDS * 4u,
                 MXQ_IMEM_WORDS * 4u, 0,
                 (i == MXQ_TRAP_WDOG) ? 200u : 0u, 1, 0, 0);
    }

    /* ---- 3. directed data, all four kernels ----------------------------- */
    for (i = 0; i < N_DIRECTED; i++) {
        gen_directed(i, data, blk);
        cast_job(K_QC, data, 1, blk, 1, 1);
        cast_job(K_QB, data, 1, blk, 1, 1);
        cast_job(K_DC, data, 1, blk, 1, 1);
        cast_job(K_DB, data, 1, blk, 1, 1);
        pair_blocks += 1;
    }

    /* ---- 4. multi-block directed ---------------------------------------- */
    for (i = 0; i < 4; i++) {
        nblk = 2 + i;
        for (b = 0; b < nblk; b++) gen_directed(i * 5 + b, data + b * blk, blk);
        cast_job(K_QC, data, nblk, blk, 1, 1);
        cast_job(K_QB, data, nblk, blk, 0, 1);
        cast_job(K_DC, data, nblk, blk, 1, 1);
        cast_job(K_DB, data, nblk, blk, 0, 1);
        pair_blocks += (uint64_t)nblk;
    }

    /* ---- 5. randomised --------------------------------------------------- */
    for (i = 0; i < n_rand; i++) {
        nblk = 1 + (int)rnd_n(3);
        for (b = 0; b < nblk; b++) gen_random(data + b * blk, blk);
        cast_job(K_QC, data, nblk, blk, i < n_rand_trace, i < n_rand_base);
        cast_job(K_DC, data, nblk, blk, i < n_rand_trace, i < n_rand_base);
        if (i < n_rand_base) {
            cast_job(K_QB, data, nblk, blk, i < 8, 1);
            cast_job(K_DB, data, nblk, blk, i < 8, 1);
            pair_blocks += (uint64_t)nblk;
        }
    }

    for (i = 0; i < njobs; i++) total_commits += jobs[i][15];

    /* ---- write everything ------------------------------------------------ */
#define OPEN(nm) do { snprintf(path, sizeof path, "%s/%s", outdir, nm); \
                      f = fopen(path, "w");                             \
                      if (!f) { perror(path); exit(1); } } while (0)

    OPEN("imem.hex");
    for (i = 0; i < imem_n; i++) fprintf(f, "%08X\n", imem_pool[i]);
    fclose(f);

    OPEN("dinit.hex");
    for (i = 0; i < dinit_n * 2; i++) fprintf(f, "%08X\n", dinit_pool[i]);
    fclose(f);

    OPEN("dexp.hex");
    for (i = 0; i < dexp_n * 2; i++) fprintf(f, "%08X\n", dexp_pool[i]);
    fclose(f);

    OPEN("trace.hex");
    for (i = 0; i < trace_n * 5; i++) fprintf(f, "%08X\n", trace_pool[i]);
    fclose(f);

    OPEN("jobs.hex");
    for (i = 0; i < njobs; i++)
        for (b = 0; b < JOBW; b++) fprintf(f, "%08X\n", jobs[i][b]);
    fclose(f);

    OPEN("mxq_const.vh");
    fprintf(f, "// generated by sw/mxq_host.c - do not edit\n");
    fprintf(f, "`define NJOBS      %d\n", njobs);
    fprintf(f, "`define JOBW       %d\n", JOBW);
    fprintf(f, "`define IMEM_WORDS %ld\n", imem_n);
    fprintf(f, "`define DINIT_N    %ld\n", dinit_n);
    fprintf(f, "`define DEXP_N     %ld\n", dexp_n);
    fprintf(f, "`define TRACE_N    %ld\n", trace_n);
    fprintf(f, "`define BLK        %d\n", blk);
    fprintf(f, "`define CSUM       32'h%08X\n", (uint32_t)MXQ_REGMAP_CSUM);
    fprintf(f, "`define VERSION_ID 32'h%08X\n", (uint32_t)MXQ_VERSION_ID);
    fclose(f);

    OPEN("sw_metrics.txt");
    fprintf(f, "jobs %d\n", njobs);
    fprintf(f, "commits %ld\n", total_commits);
    fprintf(f, "trace_entries %ld\n", trace_n);
    fprintf(f, "blk %d\n", blk);
    for (i = 0; i <= K_DB; i++) {
        static const char *nm[4] = { "quant_custom", "quant_base",
                                     "dequant_custom", "dequant_base" };
        fprintf(f, "%s jobs %llu blocks %llu elems %llu cycles %llu "
                   "instret %llu custom %llu\n",
                nm[i], (unsigned long long)tot_jobs[i],
                (unsigned long long)tot_blocks[i],
                (unsigned long long)tot_elems[i],
                (unsigned long long)tot_cycles[i],
                (unsigned long long)tot_instret[i],
                (unsigned long long)tot_custom[i]);
    }
    fprintf(f, "imem_words quant_custom %d quant_base %d dequant_custom %d "
               "dequant_base %d isa %d\n", n_qc, n_qb, n_dc, n_db, n_isa);
    fprintf(f, "paired blocks %llu qc_cycles %llu qb_cycles %llu "
               "dc_cycles %llu db_cycles %llu qc_instr %llu qb_instr %llu "
               "dc_instr %llu db_instr %llu\n",
            (unsigned long long)pair_blocks,
            (unsigned long long)pair_cyc[K_QC], (unsigned long long)pair_cyc[K_QB],
            (unsigned long long)pair_cyc[K_DC], (unsigned long long)pair_cyc[K_DB],
            (unsigned long long)pair_ins[K_QC], (unsigned long long)pair_ins[K_QB],
            (unsigned long long)pair_ins[K_DC], (unsigned long long)pair_ins[K_DB]);
    fprintf(f, "host_checks %llu\n", (unsigned long long)host_checks);
    fclose(f);

    printf("model cross-check: %llu output words from four kernels matched "
           "sw/mxq_model.c\n", (unsigned long long)host_checks);
    printf("jobs %d, commits %ld, traced %ld, imem pool %ld words\n",
           njobs, total_commits, trace_n, imem_n);
    printf("kernel sizes: quant %d/%d words (custom/base), "
           "dequant %d/%d, isa %d\n", n_qc, n_qb, n_dc, n_db, n_isa);
    return 0;
}
