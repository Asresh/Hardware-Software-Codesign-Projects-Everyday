// ============================================================================
// crc_baseline.c - documented scalar cost model (the software-only path)
//
//   The honest software baseline an HFT feed handler would run without an
//   accelerator: a byte-at-a-time table-driven CRC-32 plus per-packet framing
//   and a sequence-number lookup. We cost it, we do not race a noisy wall
//   clock, so the speedup number is reproducible.
//
//   Per-byte cost (table CRC inner loop): load table entry, XOR, shift, index
//   compute, loop test -> ~8 core cycles/byte is a conservative, widely-cited
//   figure for a portable slice-by-1 CRC that hits L1. Per-packet overhead
//   (parse header, hash channel, sequence compare/update, finalise) ~ 20
//   cycles. A bitwise (tableless) CRC - what the RTL actually mirrors - is
//   ~4x worse per byte; using the *faster* table model keeps the comparison
//   conservative.
// ============================================================================
#include "crc.h"

#define BASELINE_CPB          8ull    // cycles per byte, table-driven CRC-32
#define BASELINE_PKT_OVERHEAD 20ull   // cycles per packet, framing + seq check

uint64_t baseline_cycles(uint64_t total_crc_bytes, uint64_t total_pkts) {
    return total_crc_bytes * BASELINE_CPB + total_pkts * BASELINE_PKT_OVERHEAD;
}
