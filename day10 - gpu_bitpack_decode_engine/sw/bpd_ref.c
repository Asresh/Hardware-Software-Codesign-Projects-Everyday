// ============================================================================
// bpd_ref.c  -  bit-exact reference codec (encoder + golden decoder)
//
// Format: frame-of-reference + delta + zig-zag + LSB-first bit packing.
//   encode(vals, count, base) -> {base, {width,count}, packed residuals}
//   decode(words)             -> reconstructed values   (the golden model)
// The decoder is the golden the RTL is checked against, bit for bit.
// ============================================================================
#include "bpd.h"

// ---- LSB-first bit writer over a 32-bit word array ----
static void put_bits(uint32_t *words, size_t bitpos, uint32_t val, uint32_t nbits) {
    if (nbits == 0) return;
    uint32_t mask = (nbits >= 32) ? 0xFFFFFFFFu : ((1u << nbits) - 1u);
    val &= mask;
    size_t w = bitpos >> 5;
    uint32_t off = (uint32_t)(bitpos & 31);
    words[w] |= (val << off);
    if (off + nbits > 32) {                 // spills into the next word
        words[w + 1] |= (val >> (32 - off));
    }
}

// ---- LSB-first bit reader ----
static uint32_t get_bits(const uint32_t *words, size_t bitpos, uint32_t nbits) {
    if (nbits == 0) return 0;
    uint32_t mask = (nbits >= 32) ? 0xFFFFFFFFu : ((1u << nbits) - 1u);
    size_t w = bitpos >> 5;
    uint32_t off = (uint32_t)(bitpos & 31);
    uint32_t lo = words[w] >> off;
    if (off + nbits > 32) {                 // straddles a word boundary
        lo |= (words[w + 1] << (32 - off));
    }
    return lo & mask;
}

// Encode `count` signed values (with predecessor `base`) into `out_words`.
// Returns the number of 32-bit words produced; writes the chosen bit-width.
size_t bpd_encode(const int32_t *vals, uint32_t count, int32_t base,
                  uint32_t *out_words, uint32_t *out_width) {
    // 1) deltas -> zig-zag residuals, and the max width needed
    uint32_t width = 0;
    int32_t prev = base;
    // stash residuals in the payload region temporarily via a local scan
    // (we recompute during packing to avoid a second buffer)
    for (uint32_t i = 0; i < count; i++) {
        int32_t d = (int32_t)((uint32_t)vals[i] - (uint32_t)prev);
        uint32_t zz = zigzag_encode(d);
        uint32_t bl = u32_bitlen(zz);
        if (bl > width) width = bl;
        prev = vals[i];
    }
    if (width > 32) width = 32;

    // 2) header
    out_words[0] = (uint32_t)base;
    out_words[1] = bpd_hdr1(width, count);

    // 3) payload
    size_t pay_words = (width == 0) ? 0 : (((size_t)count * width + 31) >> 5);
    for (size_t k = 0; k < pay_words; k++) out_words[2 + k] = 0u;

    prev = base;
    for (uint32_t i = 0; i < count; i++) {
        int32_t d = (int32_t)((uint32_t)vals[i] - (uint32_t)prev);
        uint32_t zz = zigzag_encode(d);
        put_bits(out_words + 2, (size_t)i * width, zz, width);
        prev = vals[i];
    }
    *out_width = width;
    return 2 + pay_words;
}

// Golden decode: reconstruct values from a block. Returns count.
uint32_t bpd_decode_ref(const uint32_t *words, int32_t *out_vals) {
    int32_t  base  = (int32_t)words[0];
    uint32_t hdr1  = words[1];
    uint32_t width = (hdr1 >> 26) & 0x3Fu;
    uint32_t count = hdr1 & 0xFFFFu;

    int32_t running = base;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t u = get_bits(words + 2, (size_t)i * width, width);
        int32_t  d = zigzag_decode(u);
        running = (int32_t)((uint32_t)running + (uint32_t)d);
        out_vals[i] = running;
    }
    return count;
}
