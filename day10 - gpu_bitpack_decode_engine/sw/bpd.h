// ============================================================================
// bpd.h  -  shared definitions for the bit-pack decode engine
//   register map, block wire-format, and the reference codec primitives that
//   both the host (encoder + golden) and the firmware driver share.
// ============================================================================
#ifndef BPD_H
#define BPD_H

#include <stdint.h>
#include <stddef.h>

// ---- geometry (must match the RTL parameters) ----
#ifndef LANES
#define LANES 4
#endif

// ---- AXI4-Lite register map (byte offsets) ----
#define BPD_CTRL     0x00u   // [0]EN [1]IRQ_EN [2]SOFT_RST
#define BPD_STATUS   0x04u   // [0]BUSY [1]DONE [2]ERR [3]IRQ
#define BPD_BLOCKS   0x08u
#define BPD_VALUES   0x0Cu
#define BPD_CYCLES   0x10u
#define BPD_ERRCODE  0x14u
#define BPD_IRQ_ACK  0x18u
#define BPD_ID       0x1Cu
#define BPD_ID_VALUE 0xB17DEC10u

#define CTRL_EN      0x1u
#define CTRL_IRQ_EN  0x2u
#define CTRL_SOFT_RST 0x4u

#define ST_BUSY      0x1u
#define ST_DONE      0x2u
#define ST_ERR       0x4u
#define ST_IRQ       0x8u

// ---- block header word1 layout: {width[31:26], rsvd[25:16], count[15:0]} ----
static inline uint32_t bpd_hdr1(uint32_t width, uint32_t count) {
    return ((width & 0x3Fu) << 26) | (count & 0xFFFFu);
}

// ---- zig-zag mapping (delta <-> unsigned residual) ----
static inline uint32_t zigzag_encode(int32_t d) {
    // (d<<1) ^ (d>>31): all-ones when negative
    return ((uint32_t)d << 1) ^ (d < 0 ? 0xFFFFFFFFu : 0u);
}
static inline int32_t zigzag_decode(uint32_t u) {
    // (u>>1) ^ -(u&1)
    return (int32_t)((u >> 1) ^ (uint32_t)(-(int32_t)(u & 1u)));
}

// bit-length (0 for value 0)
static inline uint32_t u32_bitlen(uint32_t x) {
    uint32_t n = 0;
    while (x) { n++; x >>= 1; }
    return n;
}

#endif // BPD_H
