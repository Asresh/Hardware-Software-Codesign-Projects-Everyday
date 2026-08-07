/* ===========================================================================
 * p2p_host.c - builds the whole experiment.
 *
 * Emits, into --outdir:
 *   mem_init.hex    the shared-memory image the simulation starts from
 *   golden_mem.hex  the image it must end at, after every launch
 *   runs.txt        one line per launch: the ring parameters and every
 *                   timing-independent value the CSRs have to report
 *   p2p_const.vh    geometry + a checksum of the C register map
 *   sw_metrics.txt  the software cost-model totals
 *
 * Allocation discipline, which the whole differential test rests on: every
 * source region, destination region, work queue and completion queue comes
 * from one bump allocator, so no source region can ever alias a destination
 * region. That is what makes the final memory image a pure function of the
 * descriptor rings - the transmitter is free to read ahead of the receiver's
 * writes by any amount the bus happens to allow, and the answer does not move.
 * The allocator checks the property explicitly rather than relying on the
 * argument.
 * ===========================================================================
 */
#include "p2p.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MEM_CAP   (140u * 1024u)
#define MAX_RUNS  512
#define MAX_WQE   64

static uint32_t mem[MEM_CAP];
static uint32_t init_img[MEM_CAP];
static uint32_t gold[MEM_CAP];
static uint32_t cursor = 0;

static p2p_run_t runs[MAX_RUNS];
static char      run_name[MAX_RUNS][40];
static int       nruns = 0;
static int       peak_idx = -1, peak_acc_idx = -1;

/* region bookkeeping, used only to prove source and destination never alias */
typedef struct { uint32_t lo, hi; int is_dst; } region_t;
static region_t regions[8192];
static int nregions = 0;

/* ------------------------------------------------------------------ random */
static uint32_t rng_s = 0x2f6e2b1u;
static uint32_t rnd(void)
{
    rng_s ^= rng_s << 13;
    rng_s ^= rng_s >> 17;
    rng_s ^= rng_s << 5;
    return rng_s;
}
static uint32_t rnd_n(uint32_t n) { return n ? (rnd() % n) : 0u; }

/* ------------------------------------------------------------- allocation */
static uint32_t alloc_words(uint32_t n)
{
    uint32_t a = cursor;
    if (n == 0) n = 1;
    cursor += n;
    if (cursor >= MEM_CAP) {
        fprintf(stderr, "p2p_host: memory image overflow (%u words)\n", cursor);
        exit(1);
    }
    return a;
}

static void note_region(uint32_t lo_w, uint32_t n, int is_dst)
{
    if (n == 0) return;
    if (nregions >= (int)(sizeof(regions) / sizeof(regions[0]))) return;
    regions[nregions].lo = lo_w;
    regions[nregions].hi = lo_w + n;
    regions[nregions].is_dst = is_dst;
    nregions++;
}

static void check_no_alias(void)
{
    int i, j;
    for (i = 0; i < nregions; i++)
        for (j = i + 1; j < nregions; j++) {
            if (regions[i].is_dst == regions[j].is_dst) continue;
            if (regions[i].lo < regions[j].hi && regions[j].lo < regions[i].hi) {
                fprintf(stderr, "p2p_host: source/destination alias at %u\n",
                        regions[i].lo);
                exit(1);
            }
        }
}

/* --------------------------------------------------------- run assembly */
static p2p_wqe_t cur_w[MAX_WQE];
static int       cur_n;
static uint32_t  cur_credit, cur_inject;
static const char *cur_name;

static void run_begin(const char *name, uint32_t credit, uint32_t inject)
{
    cur_n = 0;
    cur_credit = credit;
    cur_inject = inject;
    cur_name = name;
}

/* allocate a source and a destination and append a descriptor */
static void run_add(uint32_t op, uint32_t qp, uint32_t len, uint32_t tag)
{
    uint32_t s = alloc_words(len);
    uint32_t d = alloc_words(len);
    note_region(s, len, 0);
    note_region(d, len, 1);
    cur_w[cur_n].opcode = op;
    cur_w[cur_n].qp = qp;
    cur_w[cur_n].src = s * 4u;
    cur_w[cur_n].dst = d * 4u;
    cur_w[cur_n].len = len;
    cur_w[cur_n].tag = tag;
    cur_n++;
}

/* append a descriptor with addresses supplied verbatim (rejection tests) */
static void run_add_raw(uint32_t op, uint32_t qp, uint32_t src, uint32_t dst,
                        uint32_t len, uint32_t tag)
{
    cur_w[cur_n].opcode = op;
    cur_w[cur_n].qp = qp;
    cur_w[cur_n].src = src;
    cur_w[cur_n].dst = dst;
    cur_w[cur_n].len = len;
    cur_w[cur_n].tag = tag;
    cur_n++;
}

/* last descriptor's source / destination word index */
static uint32_t last_src_w(void) { return cur_w[cur_n - 1].src >> 2; }
static uint32_t last_dst_w(void) { return cur_w[cur_n - 1].dst >> 2; }

static void run_end(void)
{
    uint32_t wq = alloc_words((uint32_t)cur_n * P2P_WQE_WORDS);
    uint32_t cq = alloc_words((uint32_t)(cur_n ? cur_n : 1) * P2P_CQE_WORDS);
    int i;

    for (i = 0; i < cur_n; i++) {
        uint32_t *e = &mem[wq + (uint32_t)i * P2P_WQE_WORDS];
        e[0] = (cur_w[i].opcode & 0xFu) | ((cur_w[i].qp & 0xFu) << 4);
        e[1] = cur_w[i].src;
        e[2] = cur_w[i].dst;
        e[3] = cur_w[i].len;
        e[4] = cur_w[i].tag & 0xFFu;
        e[5] = 0; e[6] = 0; e[7] = 0;
    }

    runs[nruns].wq_base    = wq * 4u;
    runs[nruns].wq_count   = (uint32_t)cur_n;
    runs[nruns].cq_base    = cq * 4u;
    runs[nruns].mem_limit  = 0;          /* filled in once MEMW is known */
    runs[nruns].credit_lim = cur_credit;
    runs[nruns].inject     = cur_inject;
    snprintf(run_name[nruns], sizeof(run_name[0]), "%s", cur_name);
    nruns++;
    if (nruns >= MAX_RUNS) { fprintf(stderr, "too many runs\n"); exit(1); }
}

/* ============================================================== directed */
static void build_directed(void)
{
    uint32_t i;

    run_begin("single_word", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 1, 0x11); run_end();

    run_begin("exact_mtu", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, P2P_MTU_WORDS, 0x22); run_end();

    run_begin("mtu_plus_one", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 1, P2P_MTU_WORDS + 1, 0x23); run_end();

    run_begin("zero_length", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 0, 0x24); run_end();

    run_begin("four_mtu", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 2, P2P_MTU_WORDS * 4, 0x25); run_end();

    run_begin("two_qp", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, P2P_MTU_WORDS + 3, 0x30);
    run_add(P2P_OP_WRITE, 1, P2P_MTU_WORDS + 5, 0x31); run_end();

    run_begin("accum_single", P2P_RX_BUFS, 0);
    run_add(P2P_OP_ACCUM, 0, 1, 0x40); run_end();

    run_begin("accum_mtu", P2P_RX_BUFS, 0);
    run_add(P2P_OP_ACCUM, 0, P2P_MTU_WORDS, 0x41); run_end();

    /* signed extremes: the add must wrap in 32-bit two's complement */
    run_begin("accum_wrap", P2P_RX_BUFS, 0);
    run_add(P2P_OP_ACCUM, 0, 4, 0x42);
    mem[last_src_w() + 0] = 0x7FFFFFFFu; mem[last_dst_w() + 0] = 0x00000001u;
    mem[last_src_w() + 1] = 0x80000000u; mem[last_dst_w() + 1] = 0x80000000u;
    mem[last_src_w() + 2] = 0xFFFFFFFFu; mem[last_dst_w() + 2] = 0x00000001u;
    mem[last_src_w() + 3] = 0xFFFFFFFFu; mem[last_dst_w() + 3] = 0xFFFFFFFFu;
    run_end();

    run_begin("accum_negative", P2P_RX_BUFS, 0);
    run_add(P2P_OP_ACCUM, 1, 3, 0x43);
    mem[last_src_w() + 0] = 0xFFFFFFF6u;   /* -10 */
    mem[last_src_w() + 1] = 0xFFFFFFFFu;   /*  -1 */
    mem[last_src_w() + 2] = 0x00000000u;
    mem[last_dst_w() + 0] = 0x0000000Au;   /*  10 */
    mem[last_dst_w() + 1] = 0x00000001u;
    mem[last_dst_w() + 2] = 0x00000000u;
    run_end();

    /* two accumulates onto the same destination: composition order matters */
    run_begin("accum_same_dst", P2P_RX_BUFS, 0);
    run_add(P2P_OP_ACCUM, 0, 6, 0x44);
    {
        uint32_t d = cur_w[0].dst;
        run_add(P2P_OP_ACCUM, 0, 6, 0x45);
        cur_w[1].dst = d;
    }
    run_end();

    /* overwrite then accumulate onto the same destination */
    run_begin("write_then_accum", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 5, 0x46);
    {
        uint32_t d = cur_w[0].dst;
        run_add(P2P_OP_ACCUM, 0, 5, 0x47);
        cur_w[1].dst = d;
    }
    run_end();

    run_begin("credit_one", 1, 0);
    run_add(P2P_OP_WRITE, 0, P2P_MTU_WORDS * 4, 0x50); run_end();

    run_begin("credit_two", 2, 0);
    run_add(P2P_OP_WRITE, 3 % P2P_NUM_QP, P2P_MTU_WORDS * 3 + 7, 0x51);
    run_end();

    /* sequence-gap injection: the skipped value falls on a middle packet */
    run_begin("seqskip_middle", P2P_RX_BUFS, 1);
    run_add(P2P_OP_WRITE, 0, P2P_MTU_WORDS * 3, 0x60); run_end();

    /* ... and here on the last packet of the message, so no completion is
     * posted for it and its byte count carries into the next message */
    run_begin("seqskip_last", P2P_RX_BUFS, 1);
    run_add(P2P_OP_WRITE, 0, P2P_MTU_WORDS * 2, 0x61);
    run_add(P2P_OP_WRITE, 0, P2P_MTU_WORDS, 0x62); run_end();

    run_begin("seqskip_accum", P2P_RX_BUFS, 1);
    run_add(P2P_OP_ACCUM, 1, P2P_MTU_WORDS * 3, 0x63); run_end();

    /* peak: one long message, the throughput measurement */
    run_begin("peak_write", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 2048, 0x70);
    peak_idx = nruns; run_end();

    run_begin("peak_accum", P2P_RX_BUFS, 0);
    run_add(P2P_OP_ACCUM, 0, 512, 0x71);
    peak_acc_idx = nruns; run_end();

    /* packet-rate stress: many one-word messages */
    run_begin("many_tiny", P2P_RX_BUFS, 0);
    for (i = 0; i < 16; i++) run_add(P2P_OP_WRITE, i % P2P_NUM_QP, 1, 0x80 + i);
    run_end();

    /* every queue pair, mixed opcodes */
    run_begin("all_qp_mixed", P2P_RX_BUFS, 0);
    for (i = 0; i < P2P_NUM_QP; i++)
        run_add((i & 1) ? P2P_OP_ACCUM : P2P_OP_WRITE, i,
                P2P_MTU_WORDS + i, 0x90 + i);
    run_end();

    /* ---- rejection cases ------------------------------------------------ */
    run_begin("rej_opcode", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 4, 0xA0); cur_w[0].opcode = 7; run_end();

    run_begin("rej_qp", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 4, 0xA1);
    cur_w[0].qp = P2P_NUM_QP; run_end();

    run_begin("rej_len", P2P_RX_BUFS, 0);
    run_add_raw(P2P_OP_WRITE, 0, 0, 0, P2P_MAX_MSG_WORDS + 1, 0xA2); run_end();

    run_begin("rej_align_src", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 4, 0xA3); cur_w[0].src += 2; run_end();

    run_begin("rej_align_dst", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 4, 0xA4); cur_w[0].dst += 1; run_end();

    run_begin("rej_range", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 4, 0xA5);
    cur_w[0].dst = 0xFFFF0000u; run_end();

    run_begin("rej_range_src", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 4, 0xA6);
    cur_w[0].src = 0xFFFF0000u; run_end();

    /* error priority: opcode is reported even though qp is also wrong */
    run_begin("rej_priority", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 4, 0xA7);
    cur_w[0].opcode = 9; cur_w[0].qp = P2P_NUM_QP + 1; cur_w[0].src += 2;
    run_end();

    /* good, bad, good: the ring keeps draining past a rejected descriptor */
    run_begin("mixed_reject", P2P_RX_BUFS, 0);
    run_add(P2P_OP_WRITE, 0, 7, 0xB0);
    run_add(P2P_OP_WRITE, 0, 7, 0xB1); cur_w[1].opcode = 5;
    run_add(P2P_OP_ACCUM, 1, 9, 0xB2);
    run_end();

    run_begin("empty_ring", P2P_RX_BUFS, 0);
    run_end();
}

/* ============================================================== randomised */
static void build_random(int n)
{
    int r, i;
    char nm[40];

    for (r = 0; r < n; r++) {
        int nw = 1 + (int)rnd_n(6);
        uint32_t credit = 1 + rnd_n(P2P_RX_BUFS);
        snprintf(nm, sizeof(nm), "rand%03d", r);
        run_begin(nm, credit, 0);
        for (i = 0; i < nw; i++) {
            uint32_t op  = (rnd_n(3) == 0) ? P2P_OP_ACCUM : P2P_OP_WRITE;
            uint32_t qp  = rnd_n(P2P_NUM_QP);
            uint32_t len = rnd_n(49);
            run_add(op, qp, len, rnd_n(256));
        }
        run_end();
    }
}

/* ==================================================================== main */
static void write_hex(const char *path, const uint32_t *a, uint32_t n)
{
    FILE *f = fopen(path, "w");
    uint32_t i;
    if (!f) { perror(path); exit(1); }
    for (i = 0; i < n; i++) fprintf(f, "%08x\n", a[i]);
    fclose(f);
}

int main(int argc, char **argv)
{
    const char *outdir = ".";
    char path[512];
    uint32_t memw, i;
    int r;
    p2p_cost_t cost, peak_cost;
    uint64_t tot_wqe = 0, tot_pkt = 0, tot_txw = 0, tot_rxw = 0, tot_cqe = 0;
    uint64_t tot_err = 0, tot_seq = 0;
    uint32_t regsum;
    FILE *f;

    for (i = 1; i < (uint32_t)argc; i++)
        if (!strcmp(argv[i], "--outdir") && i + 1 < (uint32_t)argc)
            outdir = argv[++i];

    /* a deterministic pseudo-random fill everywhere: payload, destinations
     * that ACCUM folds into, and the poison that proves nothing else moved */
    for (i = 0; i < MEM_CAP; i++) mem[i] = rnd();

    build_directed();
    build_random(300);
    check_no_alias();

    memw = ((cursor + 1023u) / 1024u) * 1024u;
    for (r = 0; r < nruns; r++) runs[r].mem_limit = memw * 4u;

    memcpy(init_img, mem, sizeof(uint32_t) * memw);
    memcpy(gold, mem, sizeof(uint32_t) * memw);

    p2p_cost_reset(&cost);
    p2p_cost_reset(&peak_cost);

    for (r = 0; r < nruns; r++) {
        p2p_model_run(gold, memw, &runs[r]);
        p2p_cost_run(init_img, &runs[r], &cost);
        if (r == peak_idx) p2p_cost_run(init_img, &runs[r], &peak_cost);
        tot_wqe += runs[r].st_wqe; tot_pkt += runs[r].st_pkt;
        tot_txw += runs[r].st_txw; tot_rxw += runs[r].st_rxw;
        tot_cqe += runs[r].st_cqe; tot_err += runs[r].st_err;
        tot_seq += runs[r].st_seq;
    }

    snprintf(path, sizeof(path), "%s/mem_init.hex", outdir);
    write_hex(path, init_img, memw);
    snprintf(path, sizeof(path), "%s/golden_mem.hex", outdir);
    write_hex(path, gold, memw);

    snprintf(path, sizeof(path), "%s/runs.txt", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    for (r = 0; r < nruns; r++) {
        p2p_run_t *q = &runs[r];
        fprintf(f, "%s %u %u %u %u %u %u %u %u %u %u %u %u %u %u %u %u\n",
                run_name[r], q->wq_base, q->wq_count, q->cq_base, q->mem_limit,
                q->credit_lim, q->inject, q->st_wqe, q->st_pkt, q->st_txw,
                q->st_rxw, q->st_cqe, q->st_err, q->st_seq, q->err_code,
                q->err_index, q->status_err);
    }
    fclose(f);

    /* checksum of the C-side register map, cross-checked in the testbench
     * against the same sum computed from rtl/p2p_defs.vh */
    regsum = P2P_CTRL + P2P_STATUS + P2P_WQ_BASE + P2P_WQ_COUNT + P2P_CQ_BASE +
             P2P_MEM_LIMIT + P2P_CREDIT_LIM + P2P_INJECT + P2P_IRQ_EN +
             P2P_IRQ_STAT + P2P_ERR_CODE + P2P_ERR_INFO + P2P_ST_WQE +
             P2P_ST_PKT + P2P_ST_TXW + P2P_ST_RXW + P2P_ST_CQE + P2P_ST_ERR +
             P2P_ST_SEQ + P2P_ST_CYCLES + P2P_ST_CRSTALL + P2P_ST_LKSTALL +
             P2P_ST_MEMSTALL + P2P_CAPS;

    snprintf(path, sizeof(path), "%s/p2p_const.vh", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "`define P2P_TB_MTU     %d\n", P2P_MTU_WORDS);
    fprintf(f, "`define P2P_TB_QP      %d\n", P2P_NUM_QP);
    fprintf(f, "`define P2P_TB_BUFS    %d\n", P2P_RX_BUFS);
    fprintf(f, "`define P2P_TB_MAXMSG  %d\n", P2P_MAX_MSG_WORDS);
    fprintf(f, "`define P2P_TB_NRUNS   %d\n", nruns);
    fprintf(f, "`define P2P_TB_MEMW    %u\n", memw);
    fprintf(f, "`define P2P_TB_PEAK    %d\n", peak_idx);
    fprintf(f, "`define P2P_TB_PEAKACC %d\n", peak_acc_idx);
    fprintf(f, "`define P2P_TB_PEAKLEN 2048\n");
    fprintf(f, "`define P2P_TB_PKACLEN 512\n");
    fprintf(f, "`define P2P_TB_REGSUM  %u\n", regsum);
    fclose(f);

    snprintf(path, sizeof(path), "%s/sw_metrics.txt", outdir);
    f = fopen(path, "w");
    if (!f) { perror(path); return 1; }
    fprintf(f, "runs %d\n", nruns);
    fprintf(f, "mem_words %u\n", memw);
    fprintf(f, "wqes_accepted %llu\n", (unsigned long long)tot_wqe);
    fprintf(f, "wqes_rejected %llu\n", (unsigned long long)tot_err);
    fprintf(f, "packets %llu\n", (unsigned long long)tot_pkt);
    fprintf(f, "tx_words %llu\n", (unsigned long long)tot_txw);
    fprintf(f, "rx_words %llu\n", (unsigned long long)tot_rxw);
    fprintf(f, "cqes %llu\n", (unsigned long long)tot_cqe);
    fprintf(f, "seq_drops %llu\n", (unsigned long long)tot_seq);
    fprintf(f, "baseline_cycles %llu\n",
            (unsigned long long)p2p_cost_total(&cost));
    fprintf(f, "baseline_peak_cycles %llu\n",
            (unsigned long long)p2p_cost_total(&peak_cost));
    fprintf(f, "cost_wqe_loads %llu\n", (unsigned long long)cost.wqe_loads);
    fprintf(f, "cost_pkt_builds %llu\n", (unsigned long long)cost.pkt_builds);
    fprintf(f, "cost_tx_words %llu\n", (unsigned long long)cost.tx_words);
    fprintf(f, "cost_rx_words %llu\n", (unsigned long long)cost.rx_words);
    fprintf(f, "cost_accum_words %llu\n", (unsigned long long)cost.accum_words);
    fprintf(f, "cost_cqe_posts %llu\n", (unsigned long long)cost.cqe_posts);
    fprintf(f, "cost_credit_checks %llu\n",
            (unsigned long long)cost.credit_checks);
    fclose(f);

    printf("p2p_host: %d runs, %u memory words, %llu packets, "
           "%llu payload words\n",
           nruns, memw, (unsigned long long)tot_pkt,
           (unsigned long long)tot_txw);
    return 0;
}
