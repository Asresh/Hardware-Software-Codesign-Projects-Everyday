// ============================================================================
// crc.h - shared definitions for the feed-integrity engine (SW + vectors)
// ============================================================================
#ifndef CRC_FEED_H
#define CRC_FEED_H

#include <stdint.h>
#include <stddef.h>

// ---- CRC-32/ISO-HDLC (zlib / Ethernet FCS): reflected 0xEDB88320 ----
#define CRC_POLY_REFLECTED 0xEDB88320u
#define CRC_INIT           0xFFFFFFFFu
#define CRC_XOROUT         0xFFFFFFFFu
#define CRC_KAT_CHECK      0xCBF43926u   // CRC32("123456789")

// ---- AXI4-Lite register map (byte offsets) ----
#define REG_CTRL            0x00   // [0]EN [1]IRQ_EN [2]SEQ_CHK [3]SOFT_RST
#define REG_STATUS          0x04
#define REG_PKT_COUNT       0x08
#define REG_ERR_COUNT       0x0C
#define REG_CRC_ERR_COUNT   0x10
#define REG_GAP_COUNT       0x14
#define REG_FRAME_ERR_COUNT 0x18
#define REG_BYTE_COUNT      0x1C
#define REG_LAST_CHANNEL    0x20
#define REG_LAST_SEQ        0x24
#define REG_LAST_CRC        0x28
#define REG_LAST_EXP_CRC    0x2C
#define REG_LAST_EXP_SEQ    0x30
#define REG_IRQ_ACK         0x34
#define REG_SCRATCH         0x38
#define REG_VERSION         0x3C

#define CTRL_EN       (1u << 0)
#define CTRL_IRQ_EN   (1u << 1)
#define CTRL_SEQ_CHK  (1u << 2)
#define CTRL_SOFT_RST (1u << 3)

#define STATUS_BUSY      (1u << 0)
#define STATUS_IRQ       (1u << 1)
#define STATUS_CRC_OK    (1u << 2)
#define STATUS_SEQ_OK    (1u << 3)
#define STATUS_FRAME_ERR (1u << 4)
#define STATUS_FIRST     (1u << 5)

// ---- reference CRC engine (crc_ref.c) ----
uint32_t crc32_update(uint32_t crc, const uint8_t *buf, size_t n);  // no init/xor
uint32_t crc32_bytes(const uint8_t *buf, size_t n);                 // full init+xorout

// A parsed packet's expected result (the golden model the RTL is checked to).
typedef struct {
    uint16_t channel;
    uint32_t seq;
    uint32_t crc;        // computed, finalised
    uint32_t exp_crc;    // trailer on the wire
    uint16_t plen;       // payload bytes
    int      crc_ok;
    int      seq_ok;
    int      seq_first;
    int      frame_err;
} pkt_result_t;

// Compute the golden result for one packet given the wire header bytes,
// payload, and the trailer, advancing per-channel sequence state.
void feed_golden_packet(uint16_t channel, uint32_t seq, uint16_t plen,
                        const uint8_t *payload, uint32_t trailer,
                        int seq_check, pkt_result_t *out,
                        uint32_t *last_seq, uint8_t *seq_valid);

// ---- baseline cost model (crc_baseline.c) ----
uint64_t baseline_cycles(uint64_t total_crc_bytes, uint64_t total_pkts);

#endif
