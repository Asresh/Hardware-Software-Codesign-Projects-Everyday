/* ---------------------------------------------------------------------------
 * sort_driver.c
 * Bare-metal driver for the bitonic sort engine. This is the real firmware
 * sequence a host CPU runs against the memory-mapped CSRs: verify identity,
 * program the descriptor, kick START, wait for completion (poll STATUS.DONE -
 * the same event the IRQ signals), then read back the measured cycle count.
 *
 * It compiles as ordinary C against the volatile CSR image; on silicon the
 * caller maps sort_csr_t over the peripheral's MMIO window. The data movement
 * itself is done by the engine's own DMA master, so the CPU only touches
 * control registers here - it never sorts a single key.
 * ------------------------------------------------------------------------- */
#include "sort_accel.h"

uint32_t sort_run(sort_csr_t *csr, const sort_desc_t *d)
{
    /* Fail fast if the window is not the sort engine. */
    if (csr->ident != SORT_IDENT_VALUE)
        return 0xFFFFFFFFu;

    /* Program the descriptor. */
    csr->src    = d->src_addr;
    csr->dst    = d->dst_addr;
    csr->ntiles = d->ntiles;
    csr->mode   = d->descending ? SORT_MODE_DESCENDING : SORT_MODE_ASCENDING;

    /* Enable the completion interrupt and pulse START in one write. */
    csr->ctrl = SORT_CTRL_START | SORT_CTRL_IRQ_EN;

    /* Wait for completion. On silicon this would sleep on the IRQ; polling the
     * same DONE bit keeps the driver self-contained. */
    while ((csr->status & SORT_STATUS_DONE) == 0u)
        ;

    /* Acknowledge the interrupt and return the measured hardware latency. */
    csr->ctrl = SORT_CTRL_IRQ_CLR;
    return csr->cycles;
}
