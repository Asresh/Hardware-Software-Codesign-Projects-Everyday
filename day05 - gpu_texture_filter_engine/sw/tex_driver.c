/* ---------------------------------------------------------------------------
 * tex_driver.c
 * Bare-metal firmware driver for the texture-filter engine. This is the code a
 * host CPU runs: it programs the mailbox with a job descriptor, rings the
 * doorbell, and either polls STATUS or waits on the completion interrupt, then
 * reads back the measured cycle count. It mirrors, register for register, the
 * sequence the SystemVerilog testbench drives, so the firmware and the silicon
 * agree on the contract. Compiled for a real target it would run against the
 * memory-mapped engine; here it is built to prove it compiles against the shared
 * register map (the simulation drives the same transactions directly).
 * ------------------------------------------------------------------------- */
#include "tex_accel.h"

/* the accelerator's mailbox is mapped here on the target */
#ifndef TEX_BASE
#define TEX_BASE 0x40000000u
#endif

static inline void     tex_wr(uint32_t off, uint32_t v) {
    *(volatile uint32_t *)(uintptr_t)(TEX_BASE + off) = v;
}
static inline uint32_t tex_rd(uint32_t off) {
    return *(volatile uint32_t *)(uintptr_t)(TEX_BASE + off);
}

/* Program one resample job into the mailbox and ring the doorbell. Scale factors
 * are computed on the CPU (a divide) so the engine needs no divider. */
void tex_launch(const tex_job_t *job, int irq_enable)
{
    tex_wr(TEX_REG_SRC,     job->src);
    tex_wr(TEX_REG_DST,     job->dst);
    tex_wr(TEX_REG_SRC_W,   job->src_w);
    tex_wr(TEX_REG_SRC_H,   job->src_h);
    tex_wr(TEX_REG_DST_W,   job->dst_w);
    tex_wr(TEX_REG_DST_H,   job->dst_h);
    tex_wr(TEX_REG_SCALE_X, job->scale_x);
    tex_wr(TEX_REG_SCALE_Y, job->scale_y);
    tex_wr(TEX_REG_CTRL,    TEX_CTRL_START |
                            (irq_enable ? TEX_CTRL_IRQ_EN : 0u));
}

/* Blocking completion via polling; returns the hardware cycle count. */
uint32_t tex_wait_poll(void)
{
    while ((tex_rd(TEX_REG_STATUS) & TEX_STATUS_DONE) == 0u)
        ;
    return tex_rd(TEX_REG_CYCLES);
}

/* Interrupt-handler tail: acknowledge and collect the cycle count. */
uint32_t tex_complete_isr(void)
{
    uint32_t cyc = tex_rd(TEX_REG_CYCLES);
    tex_wr(TEX_REG_CTRL, TEX_CTRL_IRQ_CLR);
    return cyc;
}

/* Convenience: configure a full source->dest resample descriptor. */
void tex_setup_job(tex_job_t *job, uint32_t src, uint32_t dst,
                   uint32_t sw, uint32_t sh, uint32_t dw, uint32_t dh)
{
    job->src = src;   job->dst = dst;
    job->src_w = sw;  job->src_h = sh;
    job->dst_w = dw;  job->dst_h = dh;
    job->scale_x = tex_scale(sw, dw);
    job->scale_y = tex_scale(sh, dh);
}
