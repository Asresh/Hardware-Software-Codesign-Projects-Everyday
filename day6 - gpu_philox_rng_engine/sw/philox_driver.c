/* ---------------------------------------------------------------------------
 * philox_driver.c
 * Bare-metal firmware driver for the Philox RNG engine. This is the code a host
 * CPU runs: it programs the mailbox with a job descriptor (destination, draw
 * count, 64-bit key, 128-bit base counter), rings the doorbell, then either
 * polls STATUS or waits on the completion interrupt, and finally reads back the
 * measured cycle count. It mirrors, register for register, the sequence the
 * SystemVerilog testbench drives, so the firmware and the silicon agree on the
 * contract. Compiled for a real target it would run against the memory-mapped
 * engine; here it is built to prove it compiles against the shared register map
 * (the simulation drives the same transactions directly).
 * ------------------------------------------------------------------------- */
#include "philox_accel.h"

/* the accelerator's mailbox is mapped here on the target */
#ifndef PHX_BASE
#define PHX_BASE 0x40000000u
#endif

static inline void     phx_wr(uint32_t off, uint32_t v) {
    *(volatile uint32_t *)(uintptr_t)(PHX_BASE + off) = v;
}
static inline uint32_t phx_rd(uint32_t off) {
    return *(volatile uint32_t *)(uintptr_t)(PHX_BASE + off);
}

/* Program one RNG job into the mailbox and ring the doorbell. The key selects
 * the stream (seed); the base counter selects the offset into it - two jobs with
 * the same key and disjoint counter ranges produce disjoint, reproducible
 * sub-streams, which is exactly how a Monte-Carlo host tiles paths across it. */
void phx_launch(const phx_job_t *job, int irq_enable)
{
    phx_wr(PHX_REG_DST,    job->dst);
    phx_wr(PHX_REG_NDRAWS, job->ndraws);
    phx_wr(PHX_REG_KEY0,   job->key[0]);
    phx_wr(PHX_REG_KEY1,   job->key[1]);
    phx_wr(PHX_REG_CTR0,   job->ctr[0]);
    phx_wr(PHX_REG_CTR1,   job->ctr[1]);
    phx_wr(PHX_REG_CTR2,   job->ctr[2]);
    phx_wr(PHX_REG_CTR3,   job->ctr[3]);
    phx_wr(PHX_REG_CTRL,   PHX_CTRL_START |
                           (irq_enable ? PHX_CTRL_IRQ_EN : 0u));
}

/* Blocking completion via polling; returns the hardware cycle count. */
uint32_t phx_wait_poll(void)
{
    while ((phx_rd(PHX_REG_STATUS) & PHX_STATUS_DONE) == 0u)
        ;
    return phx_rd(PHX_REG_CYCLES);
}

/* Interrupt-handler tail: acknowledge and collect the cycle count. */
uint32_t phx_complete_isr(void)
{
    uint32_t cyc = phx_rd(PHX_REG_CYCLES);
    phx_wr(PHX_REG_CTRL, PHX_CTRL_IRQ_CLR);
    return cyc;
}

/* Convenience: fill a descriptor for a contiguous counter range on one stream. */
void phx_setup_job(phx_job_t *job, uint32_t dst, uint32_t ndraws,
                   uint32_t key0, uint32_t key1,
                   uint32_t c0, uint32_t c1, uint32_t c2, uint32_t c3)
{
    job->dst = dst;       job->ndraws = ndraws;
    job->key[0] = key0;   job->key[1] = key1;
    job->ctr[0] = c0;     job->ctr[1] = c1;
    job->ctr[2] = c2;     job->ctr[3] = c3;
}
