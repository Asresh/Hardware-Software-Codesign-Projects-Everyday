/* ===========================================================================
 * mxq_asm.c - RV32I instruction encoder.
 *
 * Nothing clever: the six base formats, plus two patch helpers so a forward
 * branch can be emitted before its target is known.  Everything is built out
 * of unsigned arithmetic - a program image is a bit pattern, and letting a
 * signed immediate anywhere near a shift is how a generator ends up producing
 * different code under two compilers.
 * ===========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include "mxq.h"

void mxq_asm_init(mxq_asm_t *a, uint32_t *buf, int cap)
{
    a->code = buf; a->n = 0; a->cap = cap;
}

int mxq_here(const mxq_asm_t *a) { return a->n; }

static void put(mxq_asm_t *a, uint32_t w)
{
    if (a->n >= a->cap) { fprintf(stderr, "mxq_asm: image overflow\n"); exit(1); }
    a->code[a->n++] = w;
}

static uint32_t bits(uint32_t v, int hi, int lo)
{
    return (v >> lo) & ((hi - lo) >= 31 ? 0xFFFFFFFFu
                                        : ((1u << (hi - lo + 1)) - 1u));
}

void mxq_r(mxq_asm_t *a, uint32_t op, uint32_t f7, uint32_t f3,
           int rd, int rs1, int rs2)
{
    put(a, ((f7 & 0x7Fu) << 25) | (((uint32_t)rs2 & 0x1Fu) << 20) |
           (((uint32_t)rs1 & 0x1Fu) << 15) | ((f3 & 7u) << 12) |
           (((uint32_t)rd & 0x1Fu) << 7) | (op & 0x7Fu));
}

void mxq_i(mxq_asm_t *a, uint32_t op, uint32_t f3, int rd, int rs1, int32_t imm)
{
    uint32_t u = (uint32_t)imm & 0xFFFu;
    put(a, (u << 20) | (((uint32_t)rs1 & 0x1Fu) << 15) | ((f3 & 7u) << 12) |
           (((uint32_t)rd & 0x1Fu) << 7) | (op & 0x7Fu));
}

void mxq_s(mxq_asm_t *a, uint32_t f3, int rs1, int rs2, int32_t imm)
{
    uint32_t u = (uint32_t)imm & 0xFFFu;
    put(a, (bits(u, 11, 5) << 25) | (((uint32_t)rs2 & 0x1Fu) << 20) |
           (((uint32_t)rs1 & 0x1Fu) << 15) | ((f3 & 7u) << 12) |
           (bits(u, 4, 0) << 7) | MXQ_OP_STORE);
}

void mxq_b(mxq_asm_t *a, uint32_t f3, int rs1, int rs2, int32_t off)
{
    uint32_t u = (uint32_t)off & 0x1FFFu;   /* byte offset, bit 0 always 0 */
    put(a, (bits(u, 12, 12) << 31) | (bits(u, 10, 5) << 25) |
           (((uint32_t)rs2 & 0x1Fu) << 20) | (((uint32_t)rs1 & 0x1Fu) << 15) |
           ((f3 & 7u) << 12) | (bits(u, 4, 1) << 8) | (bits(u, 11, 11) << 7) |
           MXQ_OP_BRANCH);
}

void mxq_u(mxq_asm_t *a, uint32_t op, int rd, uint32_t imm20)
{
    put(a, ((imm20 & 0xFFFFFu) << 12) | (((uint32_t)rd & 0x1Fu) << 7) |
           (op & 0x7Fu));
}

void mxq_j(mxq_asm_t *a, int rd, int32_t off)
{
    uint32_t u = (uint32_t)off & 0x1FFFFFu;
    put(a, (bits(u, 20, 20) << 31) | (bits(u, 10, 1) << 21) |
           (bits(u, 11, 11) << 20) | (bits(u, 19, 12) << 12) |
           (((uint32_t)rd & 0x1Fu) << 7) | MXQ_OP_JAL);
}

/* rewrite the JAL at word `at` so it jumps to word `target` */
void mxq_patch_j(mxq_asm_t *a, int at, int target)
{
    uint32_t old = a->code[at];
    int32_t  off = (target - at) * 4;
    uint32_t u   = (uint32_t)off & 0x1FFFFFu;
    a->code[at] = (bits(u, 20, 20) << 31) | (bits(u, 10, 1) << 21) |
                  (bits(u, 11, 11) << 20) | (bits(u, 19, 12) << 12) |
                  (old & 0x00000F80u) | MXQ_OP_JAL;
}

/* rewrite the branch at word `at` so it targets word `target` */
void mxq_patch_b(mxq_asm_t *a, int at, int target)
{
    uint32_t old = a->code[at];
    int32_t  off = (target - at) * 4;
    uint32_t u   = (uint32_t)off & 0x1FFFu;
    a->code[at] = (bits(u, 12, 12) << 31) | (bits(u, 10, 5) << 25) |
                  (old & 0x01F00000u) | (old & 0x000F8000u) |
                  (old & 0x00007000u) | (bits(u, 4, 1) << 8) |
                  (bits(u, 11, 11) << 7) | MXQ_OP_BRANCH;
}
