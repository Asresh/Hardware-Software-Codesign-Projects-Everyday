/* ===========================================================================
 * mxq_driver.c - the host-side driver.
 *
 * What a serving runtime would actually link against: load a cast kernel into
 * the unit, point it at a tensor shard, start it, wait for the interrupt, and
 * turn the counters into the one number anybody asks for - how much of the
 * cast the custom instructions actually removed.
 *
 * Compile-checked by `make sw`; there is no MMIO here to run against on a
 * workstation, so the register accesses go through a pair of accessors the
 * caller supplies.
 * ===========================================================================*/
#include <stddef.h>
#include "mxq.h"

typedef struct {
    void   (*wr)(void *ctx, uint32_t off, uint32_t val);
    uint32_t (*rd)(void *ctx, uint32_t off);
    void    *ctx;
} mxq_dev_t;

typedef struct {
    uint32_t cycles, instret, custom_ops, branch_taken, loads, stores;
    uint32_t errcode, retval;
} mxq_run_t;

static void wr(const mxq_dev_t *d, uint32_t off, uint32_t v)
{ d->wr(d->ctx, off, v); }
static uint32_t rd(const mxq_dev_t *d, uint32_t off)
{ return d->rd(d->ctx, off); }

/* ---- one-time bring-up --------------------------------------------------- */
int mxq_probe(const mxq_dev_t *d, uint32_t *imem_words, uint32_t *dmem_words)
{
    uint32_t caps;
    if (rd(d, MXQ_REG_VERSION) != MXQ_VERSION_ID)      return -1;
    if (rd(d, MXQ_REG_REGMAP_CSUM) != mxq_regmap_csum()) return -2;
    caps = rd(d, MXQ_REG_CAPS);
    if (((caps >> 16) & 0xFFu) != MXQ_NCUSTOM)          return -3;
    if (imem_words) *imem_words = 1u << (caps & 0xFFu);
    if (dmem_words) *dmem_words = 1u << ((caps >> 8) & 0xFFu);
    return 0;
}

/* ---- load a program (the core must be halted) ---------------------------- */
void mxq_load_program(const mxq_dev_t *d, const uint32_t *img, uint32_t n)
{
    uint32_t i;
    wr(d, MXQ_REG_CTRL, MXQ_CTRL_SOFT_RST);
    for (i = 0; i < n; i++) wr(d, MXQ_WIN_IMEM + i * 4u, img[i]);
}

void mxq_write_data(const mxq_dev_t *d, uint32_t word, const uint32_t *src,
                    uint32_t n)
{
    uint32_t i;
    for (i = 0; i < n; i++) wr(d, MXQ_WIN_DMEM + (word + i) * 4u, src[i]);
}

void mxq_read_data(const mxq_dev_t *d, uint32_t word, uint32_t *dst, uint32_t n)
{
    uint32_t i;
    for (i = 0; i < n; i++) dst[i] = rd(d, MXQ_WIN_DMEM + (word + i) * 4u);
}

/* ---- run ----------------------------------------------------------------- */
/* Interrupt-driven in a real system; the polling loop here is what the
 * bring-up path uses and what the testbench exercises with IRQ_EN clear. */
int mxq_run(const mxq_dev_t *d, uint32_t a0, uint32_t a1, uint32_t a2,
            uint32_t a3, uint32_t instr_budget, int use_irq, mxq_run_t *out)
{
    uint32_t st;

    wr(d, MXQ_REG_START_PC, 0);
    wr(d, MXQ_REG_WDOG, instr_budget);
    wr(d, MXQ_REG_ARG0, a0);
    wr(d, MXQ_REG_ARG1, a1);
    wr(d, MXQ_REG_ARG2, a2);
    wr(d, MXQ_REG_ARG3, a3);
    wr(d, MXQ_REG_CTRL, MXQ_CTRL_START | (use_irq ? MXQ_CTRL_IRQ_EN : 0u));

    if (use_irq) {
        while ((rd(d, MXQ_REG_IRQ_STAT) & (MXQ_IRQ_DONE | MXQ_IRQ_TRAP)) == 0u)
            ;
    } else {
        do { st = rd(d, MXQ_REG_STATUS); } while ((st & MXQ_ST_HALTED) == 0u);
    }

    if (out) {
        out->cycles       = rd(d, MXQ_REG_CYCLES);
        out->instret      = rd(d, MXQ_REG_INSTRET);
        out->custom_ops   = rd(d, MXQ_REG_CUSTOM_OPS);
        out->branch_taken = rd(d, MXQ_REG_BRANCH_TAKEN);
        out->loads        = rd(d, MXQ_REG_LOADS);
        out->stores       = rd(d, MXQ_REG_STORES);
        out->errcode      = rd(d, MXQ_REG_ERRCODE);
        out->retval       = rd(d, MXQ_REG_RETVAL);
    }
    st = rd(d, MXQ_REG_STATUS);
    wr(d, MXQ_REG_IRQ_STAT, MXQ_IRQ_DONE | MXQ_IRQ_TRAP);
    return (st & MXQ_ST_TRAP) ? -(int)rd(d, MXQ_REG_ERRCODE) : 0;
}

/* ---- the report a runtime actually wants --------------------------------- */
/* CYCLES is exactly instret + taken branches + 2, so the cycles the custom
 * instructions removed can be read straight off: each one stands in for a
 * sequence of base instructions, and the counter says how many of them ran.
 * A cast whose custom_ops per element falls below three means the block loop
 * is spending its time on pointer arithmetic rather than on the cast, which is
 * the signal to raise the block size rather than to touch the hardware. */
double mxq_custom_density(const mxq_run_t *r, uint32_t elements)
{
    if (!elements) return 0.0;
    return (double)r->custom_ops / (double)elements;
}

double mxq_cycles_per_element(const mxq_run_t *r, uint32_t elements)
{
    if (!elements) return 0.0;
    return (double)r->cycles / (double)elements;
}

const char *mxq_strerror(uint32_t code)
{
    switch (code) {
    case MXQ_ERR_NONE:        return "ok";
    case MXQ_ERR_ILLEGAL:     return "illegal instruction";
    case MXQ_ERR_LOAD_ALIGN:  return "misaligned load";
    case MXQ_ERR_STORE_ALIGN: return "misaligned store";
    case MXQ_ERR_LOAD_FAULT:  return "load outside data memory";
    case MXQ_ERR_STORE_FAULT: return "store outside data memory";
    case MXQ_ERR_FETCH_FAULT: return "fetch outside instruction memory";
    case MXQ_ERR_WDOG:        return "instruction budget exhausted";
    default:                  return "unknown";
    }
}
