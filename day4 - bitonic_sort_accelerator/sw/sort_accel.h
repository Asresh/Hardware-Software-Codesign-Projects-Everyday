/* ---------------------------------------------------------------------------
 * sort_accel.h
 * Register map, descriptor definition and driver / reference API for the tiled
 * bitonic sort accelerator. Shared by the bare-metal driver, the software
 * golden model, the scalar baseline and the vector generator so the hardware,
 * the firmware and the test vectors never drift apart.
 * ------------------------------------------------------------------------- */
#ifndef SORT_ACCEL_H
#define SORT_ACCEL_H

#include <stdint.h>
#include <stddef.h>

/* ---- MMIO register byte offsets (must match rtl/sort_top.v) ---- */
#define SORT_REG_IDENT   0x00u
#define SORT_REG_CTRL    0x04u
#define SORT_REG_STATUS  0x08u
#define SORT_REG_SRC     0x0Cu
#define SORT_REG_DST     0x10u
#define SORT_REG_NTILES  0x14u
#define SORT_REG_MODE    0x18u
#define SORT_REG_CYCLES  0x1Cu

/* ---- CTRL write bits ---- */
#define SORT_CTRL_START   0x1u
#define SORT_CTRL_IRQ_EN  0x2u
#define SORT_CTRL_IRQ_CLR 0x4u

/* ---- STATUS read bits ---- */
#define SORT_STATUS_DONE  0x1u
#define SORT_STATUS_BUSY  0x2u
#define SORT_STATUS_IRQ   0x4u

/* ---- MODE bits ---- */
#define SORT_MODE_ASCENDING  0x0u
#define SORT_MODE_DESCENDING 0x1u

#define SORT_IDENT_VALUE  0x5B170004u

/* Keys per tile: the hardware sorts one N-key tile per clock. Kept here so the
 * software golden model segments the data exactly the way the network does. */
#define SORT_N 16u

/* Memory-mapped CSR image (32-bit registers on a 4-byte stride). */
typedef struct {
    volatile uint32_t ident;   /* 0x00 */
    volatile uint32_t ctrl;    /* 0x04 */
    volatile uint32_t status;  /* 0x08 */
    volatile uint32_t src;     /* 0x0C */
    volatile uint32_t dst;     /* 0x10 */
    volatile uint32_t ntiles;  /* 0x14 */
    volatile uint32_t mode;    /* 0x18 */
    volatile uint32_t cycles;  /* 0x1C */
} sort_csr_t;

/* One sort job (a DMA descriptor). */
typedef struct {
    uint32_t src_addr;   /* source base, word address       */
    uint32_t dst_addr;   /* destination base, word address   */
    uint32_t ntiles;     /* number of N-key tiles to sort     */
    int      descending; /* 1 = descending, 0 = ascending    */
} sort_desc_t;

/* ---- bare-metal driver (sw/sort_driver.c) ----
 * Programs the descriptor, starts the engine, waits for completion and returns
 * the hardware cycle count from the CYCLES register. */
uint32_t sort_run(sort_csr_t *csr, const sort_desc_t *d);

/* ---- software golden model (sw/sort_ref.c) ----
 * Sorts each contiguous N-key tile of `in` into `out`, exactly matching the
 * network's per-tile, key-only ordering. */
void sort_reference(const uint32_t *in, uint32_t *out, uint32_t ntiles, int descending);

/* ---- scalar baseline (sw/sort_baseline.c) ----
 * A software-only tiled sort plus its documented single-issue cycle model. */
void     sort_baseline(const uint32_t *in, uint32_t *out, uint32_t ntiles, int descending);
uint64_t sort_baseline_cycles(uint32_t ntiles);   /* SORT_CPT cycles / tile */

/* Scalar cost model, deliberately conservative (it under-counts, so it never
 * inflates the reported speedup). A comparison sort of N keys needs at least
 * ~N*ceil(log2(N)) key comparisons (the merge-sort floor); each compare +
 * conditional move is SORT_CPC cycles on a single-issue in-order core. Real
 * sorts do strictly more work (pivoting, recursion, branch mispredicts), all
 * ignored here. For N = 16: 16 * 4 * 2 = 128 cycles/tile. */
#define SORT_LOG2N 4u    /* ceil(log2(SORT_N)) */
#define SORT_CPC   2u    /* cycles per key compare-exchange, single-issue */
#define SORT_CPT   (SORT_CPC * SORT_N * SORT_LOG2N)   /* cycles per tile */

#endif /* SORT_ACCEL_H */
