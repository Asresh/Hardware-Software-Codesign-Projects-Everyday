/* ===========================================================================
 * mxq_asm.h - readable names for the instruction emitter.
 *
 * The kernels are built by emitting words rather than by parsing text: there
 * is no RV32I toolchain in the loop, the custom opcodes would need one
 * patching anyway, and an emitter lets the two versions of a kernel - one with
 * the MX unit, one strictly base ISA - be built from the same C file and so
 * be obviously the same algorithm.
 * ===========================================================================*/
#ifndef MXQ_ASM_H
#define MXQ_ASM_H

#include "mxq.h"

#define DEF_R(nm, f7, f3)                                                     \
    static inline void nm(mxq_asm_t *a, int rd, int rs1, int rs2)             \
    { mxq_r(a, MXQ_OP_OP, (f7), (f3), rd, rs1, rs2); }
DEF_R(A_ADD,  0x00, 0) DEF_R(A_SUB,  0x20, 0) DEF_R(A_SLL,  0x00, 1)
DEF_R(A_SLT,  0x00, 2) DEF_R(A_SLTU, 0x00, 3) DEF_R(A_XOR,  0x00, 4)
DEF_R(A_SRL,  0x00, 5) DEF_R(A_SRA,  0x20, 5) DEF_R(A_OR,   0x00, 6)
DEF_R(A_AND,  0x00, 7)
#undef DEF_R

#define DEF_I(nm, f3)                                                         \
    static inline void nm(mxq_asm_t *a, int rd, int rs1, int32_t imm)         \
    { mxq_i(a, MXQ_OP_OPIMM, (f3), rd, rs1, imm); }
DEF_I(A_ADDI, 0) DEF_I(A_SLTI, 2) DEF_I(A_SLTIU, 3)
DEF_I(A_XORI, 4) DEF_I(A_ORI, 6) DEF_I(A_ANDI, 7)
#undef DEF_I

static inline void A_SLLI(mxq_asm_t *a, int rd, int rs1, int sh)
{ mxq_i(a, MXQ_OP_OPIMM, 1, rd, rs1, sh & 0x1F); }
static inline void A_SRLI(mxq_asm_t *a, int rd, int rs1, int sh)
{ mxq_i(a, MXQ_OP_OPIMM, 5, rd, rs1, sh & 0x1F); }
static inline void A_SRAI(mxq_asm_t *a, int rd, int rs1, int sh)
{ mxq_i(a, MXQ_OP_OPIMM, 5, rd, rs1, 0x400 | (sh & 0x1F)); }

#define DEF_L(nm, f3)                                                         \
    static inline void nm(mxq_asm_t *a, int rd, int rs1, int32_t imm)         \
    { mxq_i(a, MXQ_OP_LOAD, (f3), rd, rs1, imm); }
DEF_L(A_LB, 0) DEF_L(A_LH, 1) DEF_L(A_LW, 2) DEF_L(A_LBU, 4) DEF_L(A_LHU, 5)
#undef DEF_L

#define DEF_S(nm, f3)                                                         \
    static inline void nm(mxq_asm_t *a, int rs1, int rs2, int32_t imm)        \
    { mxq_s(a, (f3), rs1, rs2, imm); }
DEF_S(A_SB, 0) DEF_S(A_SH, 1) DEF_S(A_SW, 2)
#undef DEF_S

#define DEF_B(nm, f3)                                                         \
    static inline void nm(mxq_asm_t *a, int rs1, int rs2, int32_t off)        \
    { mxq_b(a, (f3), rs1, rs2, off); }
DEF_B(A_BEQ, 0) DEF_B(A_BNE, 1) DEF_B(A_BLT, 4)
DEF_B(A_BGE, 5) DEF_B(A_BLTU, 6) DEF_B(A_BGEU, 7)
#undef DEF_B

static inline void A_LUI(mxq_asm_t *a, int rd, uint32_t imm20)
{ mxq_u(a, MXQ_OP_LUI, rd, imm20); }
static inline void A_AUIPC(mxq_asm_t *a, int rd, uint32_t imm20)
{ mxq_u(a, MXQ_OP_AUIPC, rd, imm20); }
static inline void A_JAL(mxq_asm_t *a, int rd, int32_t off)
{ mxq_j(a, rd, off); }
static inline void A_JALR(mxq_asm_t *a, int rd, int rs1, int32_t imm)
{ mxq_i(a, MXQ_OP_JALR, 0, rd, rs1, imm); }
static inline void A_ECALL(mxq_asm_t *a)
{ mxq_i(a, MXQ_OP_SYSTEM, 0, X0, X0, 0); }
static inline void A_NOP(mxq_asm_t *a)   { A_ADDI(a, X0, X0, 0); }
static inline void A_MV(mxq_asm_t *a, int rd, int rs)  { A_ADDI(a, rd, rs, 0); }
static inline void A_RET(mxq_asm_t *a)   { A_JALR(a, X0, RA, 0); }

/* custom-0 */
#define DEF_C(nm, f3)                                                         \
    static inline void nm(mxq_asm_t *a, int rd, int rs1, int rs2)             \
    { mxq_r(a, MXQ_OP_CUSTOM, 0, (f3), rd, rs1, rs2); }
DEF_C(A_MXAMAX,  MXQ_F3_AMAX)
DEF_C(A_MXSCALE, MXQ_F3_SCALE)
DEF_C(A_MXQ4,    MXQ_F3_Q4)
DEF_C(A_MXDQ,    MXQ_F3_DQ)
DEF_C(A_MXPK,    MXQ_F3_PK)
#undef DEF_C

/* li: one instruction when the value fits a signed 12-bit field, two when it
 * does not.  Callers always place labels with mxq_here(), so the variable
 * length never reaches a branch offset. */
/* sign-extend the low 12 bits without relying on the sign of a shifted int */
static inline int32_t mxq_sext12(uint32_t v)
{ return (int32_t)((v & 0xFFFu) ^ 0x800u) - 0x800; }

static inline void A_LI(mxq_asm_t *a, int rd, uint32_t v)
{
    if ((v & 0xFFFFF800u) == 0u || (v & 0xFFFFF800u) == 0xFFFFF800u) {
        A_ADDI(a, rd, X0, mxq_sext12(v));
    } else {
        uint32_t hi = (v + 0x800u) >> 12;
        A_LUI(a, rd, hi & 0xFFFFFu);
        A_ADDI(a, rd, rd, mxq_sext12(v - (hi << 12)));
    }
}

#endif /* MXQ_ASM_H */
