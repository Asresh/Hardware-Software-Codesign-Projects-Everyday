// ============================================================================
// bpd_host.c  -  vector generator, golden, and baseline harness
//
// Builds a stream of compressed market-data columns (corner cases + random),
// verifies the reference codec round-trips every block, emits the testbench
// vectors (ingress words, expected decoded values, per-block geometry) and the
// scalar-baseline cost totals the RTL is measured against.
//
//   ./bpd_host --nrand 256 --seed 0xBADC0DE --outdir tb/vectors
// ============================================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "bpd.h"

size_t   bpd_encode(const int32_t *vals, uint32_t count, int32_t base,
                     uint32_t *out_words, uint32_t *out_width);
uint32_t bpd_decode_ref(const uint32_t *words, int32_t *out_vals);
uint64_t bpd_baseline_block(uint32_t width, uint32_t count);

// ---- deterministic 64-bit LCG (portable, reproducible) ----
static uint64_t g_state;
static void     rng_seed(uint64_t s) { g_state = s ? s : 0x9E3779B97F4A7C15ull; }
static uint32_t rng_u32(void) {
    g_state = g_state * 6364136223846793005ull + 1442695040888963407ull;
    return (uint32_t)(g_state >> 33);
}
static uint32_t rng_range(uint32_t lo, uint32_t hi) { // inclusive
    return lo + (rng_u32() % (hi - lo + 1u));
}

// ---- growable buffers ----
typedef struct { uint32_t *d; size_t n, cap; } vec_t;
static void vpush(vec_t *v, uint32_t x) {
    if (v->n == v->cap) { v->cap = v->cap ? v->cap * 2 : 4096; v->d = realloc(v->d, v->cap * 4); }
    v->d[v->n++] = x;
}

// global accumulators
static vec_t   g_ing, g_gold, g_nwords, g_nvals, g_width;
static uint64_t g_baseline_cycles = 0;
static uint32_t g_min_w = 99, g_max_w = 0;

static uint32_t tmp_words[2 + 1024];   // 512 vals * 32 bits / 32 = 512 + header
static int32_t  chk_vals[1024];

// emit one block from a value array + predecessor base
static void emit_block(const int32_t *vals, uint32_t count, int32_t base) {
    uint32_t width = 0;
    size_t nwords = bpd_encode(vals, count, base, tmp_words, &width);

    // round-trip self-check: the golden must reproduce the inputs exactly
    uint32_t dc = bpd_decode_ref(tmp_words, chk_vals);
    if (dc != count) { fprintf(stderr, "encode/decode count mismatch\n"); exit(2); }
    for (uint32_t i = 0; i < count; i++) {
        if (chk_vals[i] != vals[i]) {
            fprintf(stderr, "round-trip mismatch blk val %u: got %d exp %d (w=%u)\n",
                    i, chk_vals[i], vals[i], width);
            exit(2);
        }
    }

    for (size_t k = 0; k < nwords; k++) vpush(&g_ing, tmp_words[k]);
    for (uint32_t i = 0; i < count; i++) vpush(&g_gold, (uint32_t)vals[i]);
    vpush(&g_nwords, (uint32_t)nwords);
    vpush(&g_nvals, count);
    vpush(&g_width, width);
    g_baseline_cycles += bpd_baseline_block(width, count);
    if (width < g_min_w) g_min_w = width;
    if (width > g_max_w) g_max_w = width;
}

static int32_t vbuf[1024];

// build a block whose deltas target ~w bits, then emit it
static void gen_targeted(uint32_t count, int32_t base, uint32_t w) {
    if (count > 1024) count = 1024;
    int32_t prev = base;
    for (uint32_t i = 0; i < count; i++) {
        int32_t d;
        if (w == 0) {
            d = 0;
        } else if (i == 0) {
            // pin the width: a residual with exactly bit (w-1) set
            uint32_t zz = (w >= 32) ? (0x80000000u | rng_u32())
                                    : ((1u << (w - 1)) | (rng_u32() & ((1u << (w - 1)) - 1u)));
            d = zigzag_decode(zz);
        } else {
            uint32_t bits = (w >= 32) ? rng_u32() : (rng_u32() & ((1u << w) - 1u));
            d = zigzag_decode(bits);
        }
        prev = (int32_t)((uint32_t)prev + (uint32_t)d);
        vbuf[i] = prev;
    }
    emit_block(vbuf, count, base);
}

static void gen_corners(void) {
    int32_t v1;
    // 1) single small value
    v1 = 1234; emit_block(&v1, 1, 1230);
    // 2) single value, max-width delta (INT_MIN)
    v1 = (int32_t)0x80000000; emit_block(&v1, 1, 0);
    // 3) constant run (width 0)
    for (uint32_t i = 0; i < 100; i++) vbuf[i] = -777;
    emit_block(vbuf, 100, -777);
    // 4) full 32-bit width, alternating extremes
    { int32_t p = 0; for (uint32_t i = 0; i < 64; i++) { p += (i & 1) ? (int32_t)0x7FFFFFFF : (int32_t)0x80000000; vbuf[i] = p; } }
    emit_block(vbuf, 64, 0);
    // 5) count not a multiple of LANES, small width
    gen_targeted(7, 500, 5);
    // 6) count == LANES exactly
    gen_targeted(4, -3, 9);
    // 7) count == LANES+1
    gen_targeted(5, 42, 12);
    // 8) alternating +/-1 (zig-zag stress), width 1
    { int32_t p = 0; for (uint32_t i = 0; i < 200; i++) { p += (i & 1) ? -1 : 1; vbuf[i] = p; } }
    emit_block(vbuf, 200, 0);
    // 9) strictly monotonic (all positive deltas)
    { int32_t p = 1000000; for (uint32_t i = 0; i < 300; i++) { p += (int32_t)rng_range(1, 4000); vbuf[i] = p; } }
    emit_block(vbuf, 300, 1000000);
    // 10) wrap past INT_MAX
    { int32_t p = (int32_t)0x7FFFFF00; for (uint32_t i = 0; i < 50; i++) { p += 40; vbuf[i] = p; } }
    emit_block(vbuf, 50, (int32_t)0x7FFFFF00);
    // 11) wrap past INT_MIN
    { int32_t p = (int32_t)0x80000100; for (uint32_t i = 0; i < 50; i++) { p -= 40; vbuf[i] = p; } }
    emit_block(vbuf, 50, (int32_t)0x80000100);
    // 12) large block, mid width
    gen_targeted(600, 250000, 13);
}

static void write_hex(const char *path, const vec_t *v, const char *fmt) {
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    for (size_t i = 0; i < v->n; i++) fprintf(f, fmt, v->d[i]);
    fclose(f);
}

int main(int argc, char **argv) {
    uint32_t nrand = 256;
    uint64_t seed = 0x0BADC0DEull;
    const char *outdir = "tb/vectors";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--nrand") && i + 1 < argc) nrand = (uint32_t)strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--outdir") && i + 1 < argc) outdir = argv[++i];
    }
    rng_seed(seed);

    gen_corners();
    for (uint32_t b = 0; b < nrand; b++) {
        uint32_t w     = rng_range(0, 32);
        uint32_t count = rng_range(1, 512);
        int32_t  base  = (int32_t)rng_u32();
        gen_targeted(count, base, w);
    }

    char path[512];
    snprintf(path, sizeof path, "%s/ingress.hex", outdir);   write_hex(path, &g_ing,    "%08X\n");
    snprintf(path, sizeof path, "%s/gold.hex", outdir);      write_hex(path, &g_gold,   "%08X\n");
    snprintf(path, sizeof path, "%s/blk_nwords.hex", outdir); write_hex(path, &g_nwords, "%X\n");
    snprintf(path, sizeof path, "%s/blk_nvals.hex", outdir);  write_hex(path, &g_nvals,  "%X\n");
    snprintf(path, sizeof path, "%s/blk_width.hex", outdir);  write_hex(path, &g_width,  "%X\n");

    size_t nblk = g_nvals.n;
    snprintf(path, sizeof path, "%s/bpd_const.vh", outdir);
    FILE *fc = fopen(path, "w");
    fprintf(fc, "// auto-generated by bpd_host - do not edit\n");
    fprintf(fc, "localparam integer TB_NBLK     = %zu;\n", nblk);
    fprintf(fc, "localparam integer TB_NWORDS   = %zu;\n", g_ing.n);
    fprintf(fc, "localparam integer TB_NVALS    = %zu;\n", g_gold.n);
    fprintf(fc, "localparam integer TB_BASELINE = %llu;\n", (unsigned long long)g_baseline_cycles);
    fprintf(fc, "localparam integer TB_MINW     = %u;\n", g_min_w);
    fprintf(fc, "localparam integer TB_MAXW     = %u;\n", g_max_w);
    fclose(fc);

    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir);
    FILE *fm = fopen(path, "w");
    fprintf(fm, "baseline_cycles %llu\n", (unsigned long long)g_baseline_cycles);
    fprintf(fm, "total_blocks %zu\n", nblk);
    fprintf(fm, "total_values %zu\n", g_gold.n);
    fprintf(fm, "total_words %zu\n", g_ing.n);
    fprintf(fm, "min_width %u\n", g_min_w);
    fprintf(fm, "max_width %u\n", g_max_w);
    fclose(fm);

    printf("bpd_host: %zu blocks, %zu values, %zu ingress words, width [%u..%u], baseline %llu cyc\n",
           nblk, g_gold.n, g_ing.n, g_min_w, g_max_w, (unsigned long long)g_baseline_cycles);
    return 0;
}
