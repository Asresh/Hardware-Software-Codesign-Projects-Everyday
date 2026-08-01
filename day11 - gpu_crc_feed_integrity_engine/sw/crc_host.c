// ============================================================================
// crc_host.c - host application: build feed-packet vectors + golden results
//
//   Generates a stream of well-formed market-data packets - a mix of channels,
//   payload lengths (including every partial-word tail and a large packet),
//   with a sprinkling of injected CRC corruptions and sequence gaps so the
//   engine's error paths are exercised - and writes:
//
//     ingress.hex    one packed 33-bit beat per line  {tlast, tdata[31:0]}
//     golden.txt     one expected result per packet
//     crc_const.vh   NUM_BEATS / NUM_PKTS for the testbench
//     sw_metrics.txt totals + documented baseline cost for the metrics report
//
//   The RTL is checked bit-for-bit against golden.txt; malformed-frame and
//   peak-throughput cases are constructed directly in the testbench.
// ============================================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "crc.h"

static uint64_t rng_state;
static uint32_t rnd(void) {
    // splitmix64 -> 32-bit
    uint64_t z = (rng_state += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z =  z ^ (z >> 31);
    return (uint32_t)(z >> 16);
}
static uint32_t rnd_range(uint32_t lo, uint32_t hi) { // inclusive
    return lo + (rnd() % (hi - lo + 1));
}

#define MAX_PLEN     600
#define NCH_USED     12
#define MAX_BEATS    (400 * (2 + (MAX_PLEN/4 + 1) + 1) + 4096)

static uint32_t g_beats[MAX_BEATS];   // bit32 carried separately
static uint8_t  g_last[MAX_BEATS];
static int      g_nbeat = 0;

static void emit(uint32_t data, int last) {
    g_beats[g_nbeat] = data;
    g_last[g_nbeat]  = (uint8_t)last;
    g_nbeat++;
}

int main(int argc, char **argv) {
    int nrand = 300;
    uint64_t seed = 0x0BADC0DEull;
    const char *outdir = "tb/vectors";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--nrand") && i + 1 < argc) nrand = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--outdir") && i + 1 < argc) outdir = argv[++i];
    }
    rng_state = seed;

    // forced corner-case payload lengths, appended to the random set
    static const int corner[] = {0, 1, 2, 3, 4, 5, 7, 8, 9, 16, 33, 64, 255, 256, 512};
    int ncorner = (int)(sizeof(corner) / sizeof(corner[0]));
    int npkts = nrand + ncorner;

    char path[512];
    snprintf(path, sizeof path, "%s/golden.txt", outdir);
    FILE *fg = fopen(path, "w");
    if (!fg) { perror("golden"); return 1; }

    uint32_t chan_seq[256];   // next sequence per channel
    uint32_t last_seq[256];
    uint8_t  seq_valid[256];
    memset(seq_valid, 0, sizeof seq_valid);
    for (int c = 0; c < 256; c++) chan_seq[c] = rnd_range(1, 5000);

    uint8_t payload[MAX_PLEN];
    uint64_t total_crc_bytes = 0;
    int min_plen = 1 << 30, max_plen = 0;
    int crc_injected = 0, gap_injected = 0;

    for (int p = 0; p < npkts; p++) {
        uint16_t channel = (uint16_t)(rnd_range(0, NCH_USED - 1));
        int plen;
        if (p >= nrand) {
            plen = corner[p - nrand];
            // bias corner cases onto a couple of channels so their seq is live
            channel = (uint16_t)((p - nrand) % 3);
        } else {
            // mostly short with an occasional big burst
            plen = (rnd() % 8 == 0) ? (int)rnd_range(200, MAX_PLEN)
                                    : (int)rnd_range(0, 80);
        }
        if (plen < min_plen) min_plen = plen;
        if (plen > max_plen) max_plen = plen;

        for (int b = 0; b < plen; b++) payload[b] = (uint8_t)rnd();

        // sequence number: usually contiguous, occasionally a gap
        uint32_t seq;
        int force_gap = (seq_valid[channel & 0xFF]) && (rnd() % 11 == 0);
        if (force_gap) {
            seq = chan_seq[channel] + rnd_range(1, 9);   // skip ahead -> gap
            gap_injected++;
        } else {
            seq = chan_seq[channel];
        }
        chan_seq[channel] = seq + 1;   // next contiguous value

        // correct trailer, then maybe corrupt it
        uint32_t good_crc;
        {
            uint8_t hdr[8];
            hdr[0] = plen & 0xFF; hdr[1] = (plen >> 8) & 0xFF;
            hdr[2] = channel & 0xFF; hdr[3] = (channel >> 8) & 0xFF;
            hdr[4] = seq & 0xFF; hdr[5] = (seq >> 8) & 0xFF;
            hdr[6] = (seq >> 16) & 0xFF; hdr[7] = (seq >> 24) & 0xFF;
            uint32_t c = crc32_update(CRC_INIT, hdr, 8);
            c = crc32_update(c, payload, plen);
            good_crc = c ^ CRC_XOROUT;
        }
        uint32_t trailer = good_crc;
        if (rnd() % 9 == 0) { trailer ^= (1u << (rnd() & 31)); crc_injected++; }

        // golden result
        pkt_result_t r;
        feed_golden_packet(channel, seq, (uint16_t)plen, payload, trailer,
                           /*seq_check=*/1, &r, last_seq, seq_valid);
        fprintf(fg, "%04x %08x %08x %08x %u %d %d %d\n",
                r.channel, r.seq, r.crc, r.exp_crc, r.plen,
                r.crc_ok, r.seq_ok, r.seq_first);

        // emit beats: hdr0, hdr1, payload words, trailer(tlast)
        emit(((uint32_t)channel << 16) | (uint32_t)plen, 0);
        emit(seq, 0);
        int words = (plen + 3) / 4;
        for (int w = 0; w < words; w++) {
            uint32_t d = 0;
            for (int k = 0; k < 4; k++) {
                int idx = w * 4 + k;
                if (idx < plen) d |= (uint32_t)payload[idx] << (8 * k);
            }
            emit(d, 0);
        }
        emit(trailer, 1);   // trailer carries TLAST

        total_crc_bytes += (uint64_t)(8 + plen);
    }
    fclose(fg);

    // ingress.hex : packed {tlast, tdata} as a 33-bit value (9 hex digits)
    snprintf(path, sizeof path, "%s/ingress.hex", outdir);
    FILE *fi = fopen(path, "w");
    if (!fi) { perror("ingress"); return 1; }
    for (int i = 0; i < g_nbeat; i++) {
        unsigned long long packed = ((unsigned long long)(g_last[i] & 1) << 32)
                                  | (unsigned long long)g_beats[i];
        fprintf(fi, "%09llx\n", packed);
    }
    fclose(fi);

    // crc_const.vh
    snprintf(path, sizeof path, "%s/crc_const.vh", outdir);
    FILE *fc = fopen(path, "w");
    fprintf(fc, "// generated by crc_host.c - do not edit\n");
    fprintf(fc, "`define NUM_BEATS %d\n", g_nbeat);
    fprintf(fc, "`define NUM_PKTS  %d\n", npkts);
    fclose(fc);

    // sw_metrics.txt
    uint64_t base = baseline_cycles(total_crc_bytes, (uint64_t)npkts);
    snprintf(path, sizeof path, "%s/sw_metrics.txt", outdir);
    FILE *fm = fopen(path, "w");
    fprintf(fm, "total_pkts %d\n", npkts);
    fprintf(fm, "total_beats %d\n", g_nbeat);
    fprintf(fm, "total_crc_bytes %llu\n", (unsigned long long)total_crc_bytes);
    fprintf(fm, "min_plen %d\n", min_plen);
    fprintf(fm, "max_plen %d\n", max_plen);
    fprintf(fm, "crc_injected %d\n", crc_injected);
    fprintf(fm, "gap_injected %d\n", gap_injected);
    fprintf(fm, "baseline_cpb 8\n");
    fprintf(fm, "baseline_overhead_per_pkt 20\n");
    fprintf(fm, "baseline_cycles %llu\n", (unsigned long long)base);
    fclose(fm);

    printf("crc_host: %d packets, %d beats, %llu CRC bytes "
           "(%d CRC injects, %d gap injects)\n",
           npkts, g_nbeat, (unsigned long long)total_crc_bytes,
           crc_injected, gap_injected);
    return 0;
}
