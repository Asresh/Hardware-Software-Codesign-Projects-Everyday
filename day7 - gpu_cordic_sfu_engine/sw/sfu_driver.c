/* ---------------------------------------------------------------------------
 * sfu_driver.c
 * Bare-metal firmware driver for the CORDIC SFU engine. This is the code a host
 * CPU runs: it fills request entries into the shared submission ring, programs
 * the mailbox with the ring descriptor (bases, capacity, head indices, count),
 * rings the doorbell, then either polls STATUS or waits on the completion
 * interrupt, and finally reads back results from the completion ring and the
 * measured cycle count. It mirrors, register for register, the sequence the
 * SystemVerilog testbench drives, so firmware and silicon agree on the contract.
 * Compiled for a real target it would run against the memory-mapped engine and
 * the shared device memory; here it is built to prove it compiles against the
 * shared register map (the simulation drives the same transactions directly).
 * ------------------------------------------------------------------------- */
#include "sfu_accel.h"

#ifndef SFU_BASE
#define SFU_BASE 0x40000000u          /* mailbox aperture on the target       */
#endif
#ifndef SFU_MEM
#define SFU_MEM  0x80000000u          /* shared device memory aperture        */
#endif

static inline void     sfu_wr(uint32_t off, uint32_t v) {
    *(volatile uint32_t *)(uintptr_t)(SFU_BASE + off) = v;
}
static inline uint32_t sfu_rd(uint32_t off) {
    return *(volatile uint32_t *)(uintptr_t)(SFU_BASE + off);
}
static inline void     mem_wr(uint32_t word_addr, uint32_t v) {
    *(volatile uint32_t *)(uintptr_t)(SFU_MEM + word_addr * 4u) = v;
}
static inline uint32_t mem_rd(uint32_t word_addr) {
    return *(volatile uint32_t *)(uintptr_t)(SFU_MEM + word_addr * 4u);
}

/* Push one request into the submission ring at logical index k (wrapping). */
void sfu_push_request(const sfu_job_t *job, uint32_t k,
                      uint32_t op, int32_t a, int32_t b)
{
    uint32_t idx  = (job->req_head + k) & (job->ring_cap - 1u);
    uint32_t addr = job->req_base + idx * SFU_ENTRY_WORDS;
    mem_wr(addr + 0, op);
    mem_wr(addr + 1, (uint32_t)a);
    mem_wr(addr + 2, (uint32_t)b);
    mem_wr(addr + 3, 0u);
}

/* Read back one result from the completion ring at logical index k (wrapping). */
void sfu_pop_result(const sfu_job_t *job, uint32_t k,
                    uint32_t *op, int32_t *r0, int32_t *r1)
{
    uint32_t idx  = (job->res_head + k) & (job->ring_cap - 1u);
    uint32_t addr = job->res_base + idx * SFU_ENTRY_WORDS;
    *op = mem_rd(addr + 0);
    *r0 = (int32_t)mem_rd(addr + 1);
    *r1 = (int32_t)mem_rd(addr + 2);
}

/* Program the ring descriptor into the mailbox and ring the doorbell. */
void sfu_launch(const sfu_job_t *job, int irq_enable)
{
    sfu_wr(SFU_REG_REQ_BASE, job->req_base);
    sfu_wr(SFU_REG_RES_BASE, job->res_base);
    sfu_wr(SFU_REG_RING_CAP, job->ring_cap);
    sfu_wr(SFU_REG_REQ_HEAD, job->req_head);
    sfu_wr(SFU_REG_RES_HEAD, job->res_head);
    sfu_wr(SFU_REG_COUNT,    job->count);
    sfu_wr(SFU_REG_CTRL,     SFU_CTRL_START |
                             (irq_enable ? SFU_CTRL_IRQ_EN : 0u));
}

/* Blocking completion via polling; returns the hardware cycle count. */
uint32_t sfu_wait_poll(void)
{
    while ((sfu_rd(SFU_REG_STATUS) & SFU_STATUS_DONE) == 0u)
        ;
    return sfu_rd(SFU_REG_CYCLES);
}

/* Interrupt-handler tail: acknowledge and collect the cycle count. */
uint32_t sfu_complete_isr(void)
{
    uint32_t cyc = sfu_rd(SFU_REG_CYCLES);
    sfu_wr(SFU_REG_CTRL, SFU_CTRL_IRQ_CLR);
    return cyc;
}
