/* ---------------------------------------------------------------------------
 * scan_driver.c
 * Bare-metal driver for the scan engine. This is the real firmware sequence a
 * host CPU runs against the memory-mapped CSRs: verify identity, program the
 * descriptor, kick START, wait for completion (poll STATUS.DONE - the same
 * event the IRQ signals), then read back the measured cycle count.
 *
 * It compiles as ordinary C against the volatile CSR image; on silicon the
 * caller maps scan_csr_t over the peripheral's APB window. The data movement
 * itself is done by the engine's own DMA master, so the CPU only touches
 * control registers here.
 * ------------------------------------------------------------------------- */
#include "scan_accel.h"

uint32_t scan_run(scan_csr_t *csr, const scan_desc_t *d)
{
    /* Fail fast if the window is not the scan engine. */
    if (csr->ident != SCAN_IDENT_VALUE)
        return 0xFFFFFFFFu;

    /* Program the descriptor. */
    csr->src  = d->src_addr;
    csr->dst  = d->dst_addr;
    csr->len  = d->len;
    csr->mode = d->exclusive ? SCAN_MODE_EXCLUSIVE : SCAN_MODE_INCLUSIVE;

    /* Enable the completion interrupt and pulse START in one write. */
    csr->ctrl = SCAN_CTRL_START | SCAN_CTRL_IRQ_EN;

    /* Wait for completion. On silicon this would sleep on the IRQ; polling the
     * same DONE bit keeps the driver self-contained. */
    while ((csr->status & SCAN_STATUS_DONE) == 0u)
        ;

    /* Acknowledge the interrupt and return the measured hardware latency. */
    csr->ctrl = SCAN_CTRL_IRQ_CLR;
    return csr->cycles;
}
