// ============================================================================
// crc_ref.c - bit-exact golden model the RTL is checked against
//
//   The reference CRC uses the same reflected bitwise recurrence as the
//   hardware's crc32_unit (no lookup table), so the two agree bit-for-bit by
//   construction, and the standard KAT CRC32("123456789") = 0xCBF43926 pins
//   both to the published CRC-32/ISO-HDLC value.
// ============================================================================
#include "crc.h"

// Fold one reflected byte into the running (non-finalised) state.
static uint32_t crc32_byte(uint32_t c, uint8_t d) {
    c ^= d;
    for (int i = 0; i < 8; i++)
        c = (c & 1u) ? ((c >> 1) ^ CRC_POLY_REFLECTED) : (c >> 1);
    return c;
}

uint32_t crc32_update(uint32_t crc, const uint8_t *buf, size_t n) {
    for (size_t i = 0; i < n; i++)
        crc = crc32_byte(crc, buf[i]);
    return crc;
}

uint32_t crc32_bytes(const uint8_t *buf, size_t n) {
    return crc32_update(CRC_INIT, buf, n) ^ CRC_XOROUT;
}

void feed_golden_packet(uint16_t channel, uint32_t seq, uint16_t plen,
                        const uint8_t *payload, uint32_t trailer,
                        int seq_check, pkt_result_t *out,
                        uint32_t *last_seq, uint8_t *seq_valid) {
    // Reconstruct the exact wire byte stream the CRC covers:
    //   header word 0 = {channel[15:0], plen[15:0]} little-endian
    //   header word 1 = seq              little-endian
    //   payload bytes as given (trailer itself is NOT CRC'd)
    uint32_t crc = CRC_INIT;
    uint8_t hdr[8];
    hdr[0] = (uint8_t)(plen & 0xFF);
    hdr[1] = (uint8_t)(plen >> 8);
    hdr[2] = (uint8_t)(channel & 0xFF);
    hdr[3] = (uint8_t)(channel >> 8);
    hdr[4] = (uint8_t)(seq & 0xFF);
    hdr[5] = (uint8_t)((seq >> 8) & 0xFF);
    hdr[6] = (uint8_t)((seq >> 16) & 0xFF);
    hdr[7] = (uint8_t)((seq >> 24) & 0xFF);
    crc = crc32_update(crc, hdr, 8);
    crc = crc32_update(crc, payload, plen);
    uint32_t final = crc ^ CRC_XOROUT;

    out->channel   = channel;
    out->seq       = seq;
    out->plen      = plen;
    out->crc       = final;
    out->exp_crc   = trailer;
    out->crc_ok    = (final == trailer);
    out->frame_err = 0;

    uint16_t idx = channel & 0xFF;   // NCH = 256
    if (!seq_valid[idx]) {
        out->seq_first = 1;
        out->seq_ok    = 1;
    } else {
        out->seq_first = 0;
        out->seq_ok    = seq_check ? (seq == last_seq[idx] + 1u) : 1;
    }
    // hardware updates last-seen sequence on every well-formed packet
    last_seq[idx]  = seq;
    seq_valid[idx] = 1;
}
