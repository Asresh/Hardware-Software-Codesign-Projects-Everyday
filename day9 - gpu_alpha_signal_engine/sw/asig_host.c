/* ==========================================================================
 * asig_host.c - corpus generator + golden producer for the alpha-signal engine.
 *
 * Builds a corpus of market-tick streams (random-walk price paths plus a set of
 * deterministic corner cases), runs the bit-exact software model over each, and
 * writes flat hex vectors the testbench replays:
 *
 *   ticks.hex   TOTAL_TICKS lines, 64-bit  {sym[63:32], price[31:0]}
 *   gold.hex    TOTAL_TICKS lines, 256-bit {w0..w7} signal records
 *   lens.hex    N_STREAMS   lines, tick count per stream
 *   cfg.hex     N_STREAMS   lines, 160-bit {alpha,beta,gamma,zthresh,warmup}
 *   asig_const.vh           Verilog parameters for the TB
 *   sw_metrics.txt          corpus + baseline-cycle metrics for the report
 * ========================================================================== */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "asig.h"

uint64_t asig_baseline_cycles(uint64_t n_ticks, uint64_t n_seeds);

/* ---- deterministic PRNG (xorshift64*) ---- */
static uint64_t rng_s;
static void     rng_seed(uint64_t s){ rng_s = s ? s : 0x9E3779B97F4A7C15ull; }
static uint64_t rng_u64(void){
    uint64_t x = rng_s; x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    rng_s = x; return x * 0x2545F4914F6CDD1Dull;
}
static uint32_t rng_u32(void){ return (uint32_t)(rng_u64() >> 32); }
static int      rng_range(int lo, int hi){ return lo + (int)(rng_u32() % (uint32_t)(hi - lo + 1)); }

/* Q16.16 price bounds: integer part in [1, 4000] keeps d*d within int64 with
 * generous headroom and keeps every emitted field inside its word width. */
#define PRICE_MIN  (1 << FRAC)
#define PRICE_MAX  (4000 << FRAC)
static int32_t clampp(int64_t v){
    if (v < PRICE_MIN) return PRICE_MIN;
    if (v > PRICE_MAX) return PRICE_MAX;
    return (int32_t)v;
}

/* growable buffers */
static uint64_t *tick_buf; static size_t tick_n, tick_cap;
static uint32_t (*gold_buf)[REC_WORDS]; static size_t gold_n, gold_cap;
static uint32_t  len_buf[4096]; static size_t stream_n;
static uint32_t (*cfg_buf)[5]; static size_t cfg_cap;

static void push_tick(uint32_t sym, int32_t price, const uint32_t rec[REC_WORDS]){
    if (tick_n == tick_cap){ tick_cap = tick_cap ? tick_cap*2 : 4096;
        tick_buf = realloc(tick_buf, tick_cap*sizeof *tick_buf);
        gold_buf = realloc(gold_buf, tick_cap*sizeof *gold_buf); }
    tick_buf[tick_n] = ((uint64_t)sym << 32) | (uint32_t)price;
    memcpy(gold_buf[tick_n], rec, sizeof gold_buf[0]);
    tick_n++; gold_n++;
}

/* which distinct symbols have been seen this stream (for seed counting) */
static uint8_t seen[N_SYM];
static uint64_t total_seeds;

/* emit one stream given a config and an explicit tick list */
static void run_stream(const asig_cfg_t *cfg, const asig_tick_t *ticks, int n){
    asig_state_t st[N_SYM];
    memset(st, 0, sizeof st);
    memset(seen, 0, sizeof seen);
    for (int i = 0; i < n; i++){
        uint32_t sym = ticks[i].sym % N_SYM;
        uint32_t rec[REC_WORDS];
        if (!seen[sym]){ seen[sym] = 1; total_seeds++; }
        asig_step(cfg, &st[sym], sym, ticks[i].price, rec);
        push_tick(sym, ticks[i].price, rec);
    }
    if (cfg_buf == NULL || stream_n == cfg_cap){ cfg_cap = cfg_cap ? cfg_cap*2 : 512;
        cfg_buf = realloc(cfg_buf, cfg_cap*sizeof *cfg_buf); }
    cfg_buf[stream_n][0] = (uint32_t)cfg->alpha; cfg_buf[stream_n][1] = (uint32_t)cfg->beta;
    cfg_buf[stream_n][2] = (uint32_t)cfg->gamma; cfg_buf[stream_n][3] = (uint32_t)cfg->zthresh;
    cfg_buf[stream_n][4] = cfg->warmup;
    len_buf[stream_n] = (uint32_t)n;
    stream_n++;
}

/* a random-walk stream over a random subset of symbols */
static asig_tick_t tk[8192];
static void gen_random(const asig_cfg_t *cfg, int nsym, int nt){
    int32_t px[N_SYM];
    for (int s = 0; s < N_SYM; s++) px[s] = clampp((int64_t)rng_range(2, 3999) << FRAC);
    for (int i = 0; i < nt; i++){
        uint32_t sym = (uint32_t)rng_range(0, nsym - 1);
        int32_t step = (int32_t)(rng_range(-30, 30)) << (FRAC - 4);   /* small drift */
        if ((rng_u32() & 0x3F) == 0) step = (int32_t)(rng_range(-400, 400)) << FRAC; /* jump */
        px[sym] = clampp((int64_t)px[sym] + step + (int32_t)(rng_u32() & 0xFFFF) - 0x8000);
        tk[i].sym = sym; tk[i].price = px[sym];
    }
    run_stream(cfg, tk, nt);
}

int main(int argc, char **argv){
    const char *outdir = "tb/vectors";
    int nrand = 256; uint64_t seed = 0x5EED0009ull;
    for (int i = 1; i < argc; i++){
        if (!strcmp(argv[i], "--nrand") && i+1 < argc) nrand = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i+1 < argc) seed = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--outdir") && i+1 < argc) outdir = argv[++i];
    }
    rng_seed(seed);

    /* -- self-test the sqrt kernel against libm before trusting the golden -- */
    for (int i = 0; i < 200000; i++){
        uint64_t v = rng_u64() >> (rng_u32() % 40);
        uint64_t r = asig_isqrt(v);
        uint64_t ref = (uint64_t)sqrtl((long double)v);
        while (ref*ref > v) ref--;
        while ((ref+1)*(ref+1) <= v) ref++;
        if (r != ref){ fprintf(stderr, "isqrt self-test FAIL v=%llu got=%llu ref=%llu\n",
            (unsigned long long)v,(unsigned long long)r,(unsigned long long)ref); return 2; }
    }
    rng_seed(seed);

    asig_cfg_t base = { .alpha = 6553, .beta = 1638, .gamma = 3277,
                        .zthresh = 2 << FRAC, .warmup = 8 };

    /* ---------- deterministic corner cases ---------- */
    /* 1. constant price: variance stays 0, std=0, z guarded to 0 forever */
    for (int i = 0; i < 64; i++){ tk[i].sym = 3; tk[i].price = 100 << FRAC; }
    run_stream(&base, tk, 64);
    /* 2. single symbol, long back-to-back run (RMW hazard on one address) */
    for (int i = 0; i < 400; i++){ tk[i].sym = 7;
        tk[i].price = clampp(((int64_t)(1500 + (i%50)*7) << FRAC)); }
    run_stream(&base, tk, 400);
    /* 3. two symbols strictly alternating (hazard interleave) */
    for (int i = 0; i < 300; i++){ tk[i].sym = (i&1)?11:12;
        tk[i].price = clampp(((int64_t)(800 + (i%23)*11) << FRAC)); }
    run_stream(&base, tk, 300);
    /* 4. flat then a large step (alert + z saturation) */
    for (int i = 0; i < 200; i++){ tk[i].sym = 21;
        tk[i].price = (i < 100 ? 50 : 3500) << FRAC; }
    run_stream(&base, tk, 200);
    /* 5. monotonic ramp up then down */
    for (int i = 0; i < 240; i++){ tk[i].sym = 30;
        int step = i < 120 ? i : 240 - i;
        tk[i].price = clampp(((int64_t)(20 + step*20) << FRAC)); }
    run_stream(&base, tk, 240);
    /* 6. all symbols round-robin */
    for (int i = 0; i < N_SYM*4; i++){ tk[i].sym = i % N_SYM;
        tk[i].price = clampp(((int64_t)(100 + (i%N_SYM)*40) << FRAC) + ((i&7)<<FRAC)); }
    run_stream(&base, tk, N_SYM*4);
    /* 7. price extremes alternating on one symbol */
    for (int i = 0; i < 128; i++){ tk[i].sym = 40;
        tk[i].price = (i&1)? PRICE_MAX : PRICE_MIN; }
    run_stream(&base, tk, 128);
    /* 8. tiny warmup / tiny threshold to exercise flag edges */
    { asig_cfg_t c = base; c.warmup = 2; c.zthresh = 1 << (FRAC-1);
      for (int i = 0; i < 96; i++){ tk[i].sym = 55;
          tk[i].price = clampp(((int64_t)(300 + ((i*37)%600)) << FRAC)); }
      run_stream(&c, tk, 96); }

    /* ---------- randomized streams with varied configs ---------- */
    for (int s = 0; s < nrand; s++){
        asig_cfg_t c;
        c.alpha   = 1 + (int32_t)(rng_u32() % 60000);
        c.beta    = 1 + (int32_t)(rng_u32() % (uint32_t)c.alpha);   /* slower than fast */
        c.gamma   = 1 + (int32_t)(rng_u32() % 60000);
        c.zthresh = (int32_t)(rng_range(1, 6)) << FRAC;
        c.warmup  = (uint32_t)rng_range(1, 16);
        int nsym  = rng_range(1, N_SYM);
        int nt    = rng_range(32, 400);
        gen_random(&c, nsym, nt);
    }

    /* ---------- write vectors ---------- */
    char path[512]; FILE *f;
    size_t maxlen = 0;
    for (size_t i = 0; i < stream_n; i++) if (len_buf[i] > maxlen) maxlen = len_buf[i];

    snprintf(path, sizeof path, "%s/ticks.hex", outdir); f = fopen(path, "w");
    for (size_t i = 0; i < tick_n; i++)
        fprintf(f, "%08x%08x\n", (uint32_t)(tick_buf[i] >> 32), (uint32_t)tick_buf[i]);
    fclose(f);

    snprintf(path, sizeof path, "%s/gold.hex", outdir); f = fopen(path, "w");
    for (size_t i = 0; i < gold_n; i++){
        for (int w = 0; w < REC_WORDS; w++) fprintf(f, "%08x", gold_buf[i][w]);
        fputc('\n', f);
    }
    fclose(f);

    snprintf(path, sizeof path, "%s/lens.hex", outdir); f = fopen(path, "w");
    for (size_t i = 0; i < stream_n; i++) fprintf(f, "%08x\n", len_buf[i]);
    fclose(f);

    snprintf(path, sizeof path, "%s/cfg.hex", outdir); f = fopen(path, "w");
    for (size_t i = 0; i < stream_n; i++)
        fprintf(f, "%08x%08x%08x%08x%08x\n", cfg_buf[i][0], cfg_buf[i][1],
                cfg_buf[i][2], cfg_buf[i][3], cfg_buf[i][4]);
    fclose(f);

    snprintf(path, sizeof path, "%s/asig_const.vh", outdir); f = fopen(path, "w");
    fprintf(f,
        "// generated by asig_host - do not edit\n"
        "localparam integer N_SYM      = %d;\n"
        "localparam integer SYMW       = %d;\n"
        "localparam integer FRAC       = %d;\n"
        "localparam integer PW         = 32;\n"
        "localparam integer REC_WORDS  = %d;\n"
        "localparam integer RECW       = %d;\n"
        "localparam integer TICKW      = 64;\n"
        "localparam integer CFGW       = 160;\n"
        "localparam integer N_STREAMS  = %zu;\n"
        "localparam integer MAX_TICKS  = %zu;\n"
        "localparam integer TOTAL_TICKS= %zu;\n",
        N_SYM, SYMW, FRAC, REC_WORDS, REC_WORDS*32, stream_n, maxlen, tick_n);
    fclose(f);

    uint64_t base_cycles = asig_baseline_cycles(tick_n, total_seeds);
    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir); f = fopen(path, "w");
    fprintf(f, "STREAMS %zu\n", stream_n);
    fprintf(f, "TOTAL_TICKS %zu\n", tick_n);
    fprintf(f, "TOTAL_RECORDS %zu\n", gold_n);
    fprintf(f, "TOTAL_CHECK_WORDS %zu\n", gold_n * REC_WORDS);
    fprintf(f, "SEED_TICKS %llu\n", (unsigned long long)total_seeds);
    fprintf(f, "BASELINE_CYCLES %llu\n", (unsigned long long)base_cycles);
    fclose(f);

    printf("streams=%zu ticks=%zu records=%zu seeds=%llu baseline_cycles=%llu\n",
           stream_n, tick_n, gold_n, (unsigned long long)total_seeds,
           (unsigned long long)base_cycles);
    return 0;
}
