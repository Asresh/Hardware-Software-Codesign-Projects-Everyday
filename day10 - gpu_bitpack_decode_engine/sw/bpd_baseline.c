// ============================================================================
// bpd_baseline.c  -  scalar software decoder cost model (the baseline)
//
// A straightforward (non-SIMD) scalar decoder decodes one value at a time:
// compute the bit offset, load the covering word(s), shift+mask the field,
// zig-zag decode, accumulate the delta, store. Fields that straddle a 32-bit
// word boundary pay an extra load+shift+or. The constants below are a
// documented per-operation cycle model; the engine's speedup is reported
// against the total this yields for the *same* block stream.
// ============================================================================
#include "bpd.h"

// --- documented per-operation cycle costs (issue-limited scalar core) ---
enum {
    C_HDR       = 6,   // parse base + {width,count} header
    C_OFFSET    = 1,   // bit offset / word index
    C_LOAD      = 1,   // load covering word
    C_SHIFTMASK = 2,   // barrel shift + AND mask
    C_CROSS     = 3,   // extra load + shift + OR when field spans two words
    C_ZZ        = 2,   // zig-zag decode (shift, and, xor)
    C_ADD       = 1,   // delta accumulate
    C_STORE     = 1,   // store result
    C_LOOP      = 2    // index increment + loop branch
};

// Cycles a scalar decoder spends on one block (width bits/value, count values).
uint64_t bpd_baseline_block(uint32_t width, uint32_t count) {
    uint64_t cyc = C_HDR;
    uint64_t per_val = (uint64_t)C_ZZ + C_ADD + C_STORE + C_LOOP;
    if (width > 0)
        per_val += (uint64_t)C_OFFSET + C_LOAD + C_SHIFTMASK;
    cyc += per_val * count;

    // word-boundary crossings are deterministic from the packing geometry
    if (width > 0) {
        for (uint32_t i = 0; i < count; i++) {
            uint32_t off = ((uint64_t)i * width) & 31u;
            if (off + width > 32u) cyc += C_CROSS;
        }
    }
    return cyc;
}
