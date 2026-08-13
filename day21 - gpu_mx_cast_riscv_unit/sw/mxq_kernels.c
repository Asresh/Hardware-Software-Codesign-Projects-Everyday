/* ===========================================================================
 * mxq_kernels.c - the four cast kernels, plus the ISA conformance and trap
 * programs.
 *
 * Each cast exists twice: once using custom-0, once using nothing but base
 * RV32I.  They are emitted from the same file, run on the same core, over the
 * same data, and are required to leave byte-identical memory behind - so the
 * speedup this day reports is a measured cycle ratio between two programs, not
 * a comparison against a cost model of a machine that was never built.
 *
 * Calling convention for the four casts:
 *     a0 = input byte address, a1 = output byte address,
 *     a2 = block count,        a3 = elements per block
 *     a0 on return = blocks completed
 *
 * Register allocation is fixed across a kernel so the two versions differ only
 * where the algorithm does:
 *     s0 = 0x7F80 (non-finite threshold)   s1 = 0x7F7F (max finite magnitude)
 *     s2 = shared scale of the block       s3 = input pointer
 *     s4 = output pointer                  s5 = blocks remaining
 *     s6 = elements per block              s7 = running amax
 *     s8 = element pointer                 s9 = inner counter
 *     s10 = pack accumulator                s11 = blocks completed
 *     t0-t6, a4-a7 = leaf-routine scratch (no nested calls, so ra is safe)
 * ===========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include "mxq_asm.h"

/* ---- shared prologue: copy the arguments into the fixed allocation ------- */
static void prologue(mxq_asm_t *a)
{
    A_LI(a, S0, 0x7F80u);
    A_LI(a, S1, 0x7F7Fu);
    A_MV(a, S3, A0);
    A_MV(a, S4, A1);
    A_MV(a, S5, A2);
    A_MV(a, S6, A3);
    A_LI(a, S11, 0);
}

/* a0 = blocks completed, then stop */
static void epilogue(mxq_asm_t *a)
{
    A_MV(a, A0, S11);
    A_ECALL(a);
}

/* advance s3/s4 past one block and loop while blocks remain.
 * input block  = blk/2 words = blk*2 bytes
 * output block = 1 + blk/8 words = 4 + blk/2 bytes */
static void advance_quant(mxq_asm_t *a, int top)
{
    A_SLLI(a, T0, S6, 1);          /* blk*2 */
    A_ADD(a, S3, S3, T0);
    A_SRLI(a, T0, S6, 1);          /* blk/2 */
    A_ADDI(a, T0, T0, 4);
    A_ADD(a, S4, S4, T0);
    A_ADDI(a, S5, S5, -1);
    A_ADDI(a, S11, S11, 1);
    {
        int fix = mxq_here(a);
        A_BNE(a, S5, X0, 0);
        mxq_patch_b(a, fix, top);
    }
}

static void advance_dequant(mxq_asm_t *a, int top)
{
    A_SRLI(a, T0, S6, 1);          /* blk/2 */
    A_ADDI(a, T0, T0, 4);
    A_ADD(a, S3, S3, T0);
    A_SLLI(a, T0, S6, 1);          /* blk*2 */
    A_ADD(a, S4, S4, T0);
    A_ADDI(a, S5, S5, -1);
    A_ADDI(a, S11, S11, 1);
    {
        int fix = mxq_here(a);
        A_BNE(a, S5, X0, 0);
        mxq_patch_b(a, fix, top);
    }
}

/* =========================================================================
 * 1. quantise, with custom-0
 * ========================================================================= */
int mxq_build_quant_custom(uint32_t *img, int cap)
{
    mxq_asm_t as, *a = &as;
    int top, l1, l2, fix;
    mxq_asm_init(a, img, cap);
    prologue(a);

    top = mxq_here(a);
    /* --- pass 1: block amax, two elements per instruction --------------- */
    A_MV(a, S8, S3);
    A_SRLI(a, S9, S6, 1);
    A_LI(a, S7, 0);
    l1 = mxq_here(a);
    A_LW(a, T1, S8, 0);
    A_MXAMAX(a, S7, T1, S7);
    A_ADDI(a, S8, S8, 4);
    A_ADDI(a, S9, S9, -1);
    fix = mxq_here(a); A_BNE(a, S9, X0, 0); mxq_patch_b(a, fix, l1);

    /* --- shared scale, one instruction ---------------------------------- */
    A_MXSCALE(a, S2, S7, X0);
    A_SW(a, S4, S2, 0);

    /* --- pass 2: four elements packed into a byte, four bytes to a word -- */
    A_MV(a, S8, S3);
    A_ADDI(a, T6, S4, 4);
    A_SRLI(a, S9, S6, 3);
    l2 = mxq_here(a);
    A_LI(a, S10, 0);
    for (int k = 0; k < 4; k++) {
        A_LW(a, T1, S8, 4 * k);
        A_MXQ4(a, T2, T1, S2);
        A_MXPK(a, S10, S10, T2);
    }
    A_ADDI(a, S8, S8, 16);
    A_SW(a, T6, S10, 0);
    A_ADDI(a, T6, T6, 4);
    A_ADDI(a, S9, S9, -1);
    fix = mxq_here(a); A_BNE(a, S9, X0, 0); mxq_patch_b(a, fix, l2);

    advance_quant(a, top);
    epilogue(a);
    return mxq_here(a);
}

/* =========================================================================
 * 2. quantise, base RV32I only
 *
 * Two leaf routines carry the work the custom unit does in one instruction
 * each: bamax_half folds one bf16 into the running amax, bquant_elem turns
 * one bf16 into one E2M1 code.  Both are written the way this would actually
 * be written by hand - branchless where the branch would be unpredictable,
 * a branch where it would not - because a strawman baseline would make the
 * speedup meaningless.
 * ========================================================================= */
static int emit_bamax_half(mxq_asm_t *a)
{
    int ent = mxq_here(a), f1, f2, f3;
    A_SLLI(a, T1, A4, 17);
    A_SRLI(a, T1, T1, 17);              /* magnitude field                   */
    f1 = mxq_here(a); A_BLTU(a, T1, S0, 0);
    A_MV(a, T1, S1);                    /* Inf / NaN -> max finite           */
    mxq_patch_b(a, f1, mxq_here(a));
    A_SRLI(a, T2, T1, 7);
    f2 = mxq_here(a); A_BNE(a, T2, X0, 0);
    A_LI(a, T1, 0);                     /* subnormal -> zero                 */
    mxq_patch_b(a, f2, mxq_here(a));
    f3 = mxq_here(a); A_BLTU(a, T1, S7, 0);
    A_MV(a, S7, T1);
    mxq_patch_b(a, f3, mxq_here(a));
    A_RET(a);
    return ent;
}

/* a4 = bf16 (zero-extended), s2 = scale -> a5 = code */
static int emit_bquant_elem(mxq_asm_t *a)
{
    int ent = mxq_here(a);
    int f_fin, f_zero, f_sat, f_neg, f_big;
    int j_lad[3];
    int lad;

    A_SRLI(a, T0, A4, 15);              /* sign                              */
    A_SLLI(a, T1, A4, 17);
    A_SRLI(a, T1, T1, 17);              /* magnitude                         */
    f_fin = mxq_here(a); A_BLTU(a, T1, S0, 0);
    A_MV(a, T1, S1);
    mxq_patch_b(a, f_fin, mxq_here(a));

    A_SRLI(a, T2, T1, 7);               /* biased exponent                   */
    f_zero = mxq_here(a); A_BNE(a, T2, X0, 0);
    A_SLLI(a, A5, T0, 3);               /* signed zero, code 0               */
    A_RET(a);
    mxq_patch_b(a, f_zero, mxq_here(a));

    A_ANDI(a, T3, T1, 0x7F);
    A_ORI(a, T3, T3, 0x80);             /* significand 1.mmmmmmm as 8 bits   */
    A_SUB(a, T4, T2, S2);
    A_ADDI(a, T4, T4, 1);               /* sh = exp - scale + 1              */

    A_ADDI(a, A7, X0, 5);
    f_sat = mxq_here(a); A_BLT(a, T4, A7, 0);
    A_ADDI(a, T5, X0, -1);
    A_SRLI(a, T5, T5, 20);              /* u = 4095 (saturated)              */
    A_LI(a, T6, 0);
    j_lad[0] = mxq_here(a); A_JAL(a, X0, 0);
    mxq_patch_b(a, f_sat, mxq_here(a));

    f_neg = mxq_here(a); A_BGE(a, T4, X0, 0);
    A_SUB(a, A6, X0, T4);               /* n = -sh                           */
    A_ADDI(a, A7, X0, 32);
    f_big = mxq_here(a); A_BLT(a, A6, A7, 0);
    A_LI(a, T5, 0);
    A_LI(a, T6, 1);                     /* everything shifted out            */
    j_lad[1] = mxq_here(a); A_JAL(a, X0, 0);
    mxq_patch_b(a, f_big, mxq_here(a));
    A_SRL(a, T5, T3, A6);               /* u                                 */
    A_ADDI(a, A7, X0, 1);
    A_SLL(a, A7, A7, A6);
    A_ADDI(a, A7, A7, -1);
    A_AND(a, A7, T3, A7);
    A_SLTU(a, T6, X0, A7);              /* sticky                            */
    j_lad[2] = mxq_here(a); A_JAL(a, X0, 0);
    mxq_patch_b(a, f_neg, mxq_here(a));
    A_SLL(a, T5, T3, T4);
    A_LI(a, T6, 0);

    lad = mxq_here(a);
    for (int i = 0; i < 3; i++) mxq_patch_j(a, j_lad[i], lad);

    /* the E2M1 grid, decided by seven comparisons.  Ties at an even-index
     * midpoint go down, at an odd-index midpoint go up; adding the sticky bit
     * to u folds "strictly above the midpoint" into the same compare. */
    A_ADD(a, A6, T5, T6);               /* uS = u + sticky                   */
    A_LI(a, A5, 0);
    for (int k = 0; k < MXQ_NTHRESH; k++) {
        int odd = k & 1;
        int32_t imm = odd ? (int32_t)MXQ_THRESH[k]
                          : (int32_t)MXQ_THRESH[k] + 1;
        A_SLTIU(a, A7, odd ? T5 : A6, imm);
        A_XORI(a, A7, A7, 1);
        A_ADD(a, A5, A5, A7);
    }
    A_SLLI(a, T0, T0, 3);
    A_OR(a, A5, A5, T0);
    A_RET(a);
    return ent;
}

int mxq_build_quant_base(uint32_t *img, int cap)
{
    mxq_asm_t as, *a = &as;
    int top, l1, l2, fix, j_over, amax_ent, quant_ent;
    int f_sc0, j_scd;

    mxq_asm_init(a, img, cap);
    prologue(a);
    j_over = mxq_here(a); A_JAL(a, X0, 0);
    amax_ent  = emit_bamax_half(a);
    quant_ent = emit_bquant_elem(a);
    mxq_patch_j(a, j_over, mxq_here(a));

    top = mxq_here(a);
    A_MV(a, S8, S3);
    A_SRLI(a, S9, S6, 1);
    A_LI(a, S7, 0);
    l1 = mxq_here(a);
    A_LW(a, A3, S8, 0);
    A_SLLI(a, A4, A3, 16);
    A_SRLI(a, A4, A4, 16);
    fix = mxq_here(a); A_JAL(a, RA, 0); mxq_patch_j(a, fix, amax_ent);
    A_SRLI(a, A4, A3, 16);
    fix = mxq_here(a); A_JAL(a, RA, 0); mxq_patch_j(a, fix, amax_ent);
    A_ADDI(a, S8, S8, 4);
    A_ADDI(a, S9, S9, -1);
    fix = mxq_here(a); A_BNE(a, S9, X0, 0); mxq_patch_b(a, fix, l1);

    /* shared scale: exp(amax) - EMAX_ELEM, floored at zero */
    A_SRLI(a, T0, S7, 7);
    f_sc0 = mxq_here(a); A_BEQ(a, T0, X0, 0);
    A_ADDI(a, T0, T0, -MXQ_EMAX_ELEM);
    {
        int f = mxq_here(a); A_BGE(a, T0, X0, 0);
        A_LI(a, T0, 0);
        mxq_patch_b(a, f, mxq_here(a));
    }
    A_MV(a, S2, T0);
    j_scd = mxq_here(a); A_JAL(a, X0, 0);
    mxq_patch_b(a, f_sc0, mxq_here(a));
    A_LI(a, S2, 0);
    mxq_patch_j(a, j_scd, mxq_here(a));
    A_SW(a, S4, S2, 0);

    A_MV(a, S8, S3);
    A_ADDI(a, A1, S4, 4);               /* output pointer for code words     */
    A_SRLI(a, S9, S6, 3);
    l2 = mxq_here(a);
    A_LI(a, S10, 0);
    for (int k = 0; k < 4; k++) {
        A_LW(a, A2, S8, 4 * k);
        A_SLLI(a, A4, A2, 16);
        A_SRLI(a, A4, A4, 16);
        fix = mxq_here(a); A_JAL(a, RA, 0); mxq_patch_j(a, fix, quant_ent);
        A_MV(a, A0, A5);
        A_SRLI(a, A4, A2, 16);
        fix = mxq_here(a); A_JAL(a, RA, 0); mxq_patch_j(a, fix, quant_ent);
        A_SLLI(a, A5, A5, 4);
        A_OR(a, A5, A5, A0);            /* one byte, two codes               */
        A_SRLI(a, S10, S10, 8);
        A_SLLI(a, A5, A5, 24);
        A_OR(a, S10, S10, A5);
    }
    A_ADDI(a, S8, S8, 16);
    A_SW(a, A1, S10, 0);
    A_ADDI(a, A1, A1, 4);
    A_ADDI(a, S9, S9, -1);
    fix = mxq_here(a); A_BNE(a, S9, X0, 0); mxq_patch_b(a, fix, l2);

    advance_quant(a, top);
    epilogue(a);
    return mxq_here(a);
}

/* =========================================================================
 * 3. dequantise, with custom-0
 * ========================================================================= */
int mxq_build_dequant_custom(uint32_t *img, int cap)
{
    mxq_asm_t as, *a = &as;
    int top, l1, fix;
    mxq_asm_init(a, img, cap);
    prologue(a);

    top = mxq_here(a);
    A_LW(a, S2, S3, 0);                 /* shared scale                      */
    A_ADDI(a, S8, S3, 4);
    A_MV(a, T6, S4);
    A_SRLI(a, S9, S6, 3);
    l1 = mxq_here(a);
    A_LW(a, T1, S8, 0);
    for (int k = 0; k < 4; k++) {
        A_MXDQ(a, T2, T1, S2);
        A_SW(a, T6, T2, 4 * k);
        A_SRLI(a, T1, T1, 8);
    }
    A_ADDI(a, T6, T6, 16);
    A_ADDI(a, S8, S8, 4);
    A_ADDI(a, S9, S9, -1);
    fix = mxq_here(a); A_BNE(a, S9, X0, 0); mxq_patch_b(a, fix, l1);

    advance_dequant(a, top);
    epilogue(a);
    return mxq_here(a);
}

/* =========================================================================
 * 4. dequantise, base RV32I only
 *
 * a4 = code (4 bits), s2 = scale -> a5 = bf16.  The E2M1 tables are folded
 * into arithmetic rather than loaded, because a table would have to live in
 * data memory and the comparison is about instructions, not about who gets to
 * put constants where.
 * ========================================================================= */
static int emit_bdequant_elem(mxq_asm_t *a)
{
    int ent = mxq_here(a), f_zero, f_lo, f_hi;
    A_SRLI(a, T0, A4, 3);
    A_ANDI(a, T0, T0, 1);               /* sign                              */
    A_SLLI(a, T0, T0, 15);
    A_ANDI(a, T1, A4, 7);               /* magnitude code                    */
    f_zero = mxq_here(a); A_BEQ(a, T1, X0, 0);

    A_SRLI(a, T2, T1, 1);
    A_ADDI(a, T3, T2, -1);              /* exponent offset                   */
    A_ADD(a, T3, T3, S2);               /* e = scale + offset                */
    A_ANDI(a, T4, T1, 1);
    A_SLTU(a, T5, X0, T2);
    A_AND(a, T4, T4, T5);
    A_SLLI(a, T4, T4, 6);               /* mantissa: 0x40 for 1.5, 3, 6      */

    f_lo = mxq_here(a); A_BGE(a, X0, T3, 0);     /* e <= 0 -> flush          */
    A_ADDI(a, T5, X0, 255);
    f_hi = mxq_here(a); A_BGE(a, T3, T5, 0);     /* e >= 255 -> clamp        */
    A_SLLI(a, T3, T3, 7);
    A_OR(a, A5, T0, T3);
    A_OR(a, A5, A5, T4);
    A_RET(a);

    mxq_patch_b(a, f_hi, mxq_here(a));
    A_OR(a, A5, T0, S1);
    A_RET(a);

    mxq_patch_b(a, f_zero, mxq_here(a));
    mxq_patch_b(a, f_lo, mxq_here(a));
    A_MV(a, A5, T0);
    A_RET(a);
    return ent;
}

int mxq_build_dequant_base(uint32_t *img, int cap)
{
    mxq_asm_t as, *a = &as;
    int top, l1, fix, j_over, dq_ent;
    mxq_asm_init(a, img, cap);
    prologue(a);
    j_over = mxq_here(a); A_JAL(a, X0, 0);
    dq_ent = emit_bdequant_elem(a);
    mxq_patch_j(a, j_over, mxq_here(a));

    top = mxq_here(a);
    A_LW(a, S2, S3, 0);
    A_ADDI(a, S8, S3, 4);
    A_MV(a, T6, S4);
    A_SRLI(a, S9, S6, 3);
    l1 = mxq_here(a);
    A_LW(a, A2, S8, 0);
    for (int k = 0; k < 4; k++) {
        A_ANDI(a, A4, A2, 0xF);
        fix = mxq_here(a); A_JAL(a, RA, 0); mxq_patch_j(a, fix, dq_ent);
        A_MV(a, A1, A5);
        A_SRLI(a, A2, A2, 4);
        A_ANDI(a, A4, A2, 0xF);
        fix = mxq_here(a); A_JAL(a, RA, 0); mxq_patch_j(a, fix, dq_ent);
        A_SLLI(a, A5, A5, 16);
        A_OR(a, A5, A5, A1);
        A_SW(a, T6, A5, 4 * k);
        A_SRLI(a, A2, A2, 4);
    }
    A_ADDI(a, T6, T6, 16);
    A_ADDI(a, S8, S8, 4);
    A_ADDI(a, S9, S9, -1);
    fix = mxq_here(a); A_BNE(a, S9, X0, 0); mxq_patch_b(a, fix, l1);

    advance_dequant(a, top);
    epilogue(a);
    return mxq_here(a);
}

/* =========================================================================
 * 5. ISA conformance program
 *
 * a0 = result byte address, a1 = scratch byte address.  Every result is
 * stored to a fixed slot and every slot has a hand-written expected value in
 * MXQ_ISA_EXPECT, so the core and the simulator are not each other's only
 * witness: if both got sign-extension on LB wrong in the same way, this table
 * still says so.
 * ========================================================================= */
const uint32_t MXQ_ISA_EXPECT[MXQ_ISA_SLOTS] = {
    /*  0 addi   */ 2u,
    /*  1 sub    */ 0xFFFFFFF9u,
    /*  2 sll    */ 0x80000000u,
    /*  3 srl    */ 0x08000000u,
    /*  4 sra    */ 0xF8000000u,
    /*  5 sra 0  */ 0x80000000u,
    /*  6 slt    */ 1u,
    /*  7 sltu   */ 0u,
    /*  8 xor    */ 0xFF00FF00u,
    /*  9 or     */ 0xFFF0FFF0u,
    /* 10 and    */ 0x00F000F0u,
    /* 11 andi-1 */ 0xF0F0F0F0u,
    /* 12 slti   */ 1u,
    /* 13 sltiu  */ 0u,
    /* 14 lui    */ 0xABCDE000u,
    /* 15 lb     */ 0xFFFFFF80u,
    /* 16 lbu    */ 0x00000080u,
    /* 17 lh     */ 0xFFFF8123u,
    /* 18 lhu    */ 0x00008123u,
    /* 19 sb     */ 0xAABB11DDu,
    /* 20 sh     */ 0x2233CCDDu,
    /* 21 branch */ 26u,
    /* 22 loop   */ 30u,
    /* 23 jal    */ 7u,
    /* 24 mxamax */ 0x00004000u,
    /* 25 mxscale*/ 126u,
    /* 26 mxq4   */ 0x000000E4u,
    /* 27 mxdq   */ 0xC0003F80u,
    /* 28 mxpk   */ 0xAA112233u,
    /* 29 auipc  */ 0u,
    /* 30 xori-1 */ 0xF0F0F0F0u,
    /* 31 srai   */ 0xFF000000u,
    /* 32 slli   */ 0x00000020u
};

int mxq_build_isa_test(uint32_t *img, int cap)
{
    mxq_asm_t as, *a = &as;
    int slot = 0, fix, j_over, sub_ent, loop;
    mxq_asm_init(a, img, cap);

#define PUT(r) do { A_SW(a, S3, (r), 4 * slot); slot++; } while (0)

    A_MV(a, S3, A0);
    A_MV(a, S4, A1);
    j_over = mxq_here(a); A_JAL(a, X0, 0);
    sub_ent = mxq_here(a);
    A_ADDI(a, A5, X0, 7);
    A_RET(a);
    mxq_patch_j(a, j_over, mxq_here(a));

    /* --- integer register-immediate and register-register ---------------- */
    A_LI(a, T0, 5);          A_ADDI(a, T1, T0, -3);            PUT(T1);
    A_LI(a, T0, 3);          A_LI(a, T1, 10);
    A_SUB(a, T2, T0, T1);                                      PUT(T2);
    A_LI(a, T0, 1);          A_LI(a, T1, 31);
    A_SLL(a, T2, T0, T1);                                      PUT(T2);
    A_LI(a, T1, 4);          A_SRL(a, T3, T2, T1);             PUT(T3);
    A_SRA(a, T3, T2, T1);                                      PUT(T3);
    A_LI(a, T1, 0);          A_SRA(a, T3, T2, T1);             PUT(T3);
    A_LI(a, T0, -1);         A_LI(a, T1, 1);
    A_SLT(a, T2, T0, T1);                                      PUT(T2);
    A_SLTU(a, T2, T0, T1);                                     PUT(T2);
    A_LI(a, T0, 0xF0F0F0F0u); A_LI(a, T1, 0x0FF00FF0u);
    A_XOR(a, T2, T0, T1);                                      PUT(T2);
    A_OR(a, T2, T0, T1);                                       PUT(T2);
    A_AND(a, T2, T0, T1);                                      PUT(T2);
    A_ANDI(a, T2, T0, -1);                                     PUT(T2);
    A_LI(a, T0, -5);         A_SLTI(a, T2, T0, -4);            PUT(T2);
    A_LI(a, T0, -1);         A_SLTIU(a, T2, T0, -1);           PUT(T2);
    A_LUI(a, T2, 0xABCDEu);                                    PUT(T2);

    /* --- loads, stores and their sub-word behaviour ---------------------- */
    A_LI(a, T0, 0x12345680u); A_SW(a, S4, T0, 4);
    A_LI(a, T0, 0x00008123u); A_SW(a, S4, T0, 8);
    A_LI(a, T0, 0xAABBCCDDu); A_SW(a, S4, T0, 12);
    A_SW(a, S4, T0, 16);
    A_LB (a, T2, S4, 4);                                       PUT(T2);
    A_LBU(a, T2, S4, 4);                                       PUT(T2);
    A_LH (a, T2, S4, 8);                                       PUT(T2);
    A_LHU(a, T2, S4, 8);                                       PUT(T2);
    A_LI(a, T0, 0x11);       A_SB(a, S4, T0, 13);
    A_LW(a, T2, S4, 12);                                       PUT(T2);
    A_LI(a, T0, 0x2233);     A_SH(a, S4, T0, 18);
    A_LW(a, T2, S4, 16);                                       PUT(T2);

    /* --- every branch condition, taken and not taken --------------------- */
    A_LI(a, T0, 0);  A_LI(a, T1, -1);  A_LI(a, T2, 1);
    fix = mxq_here(a); A_BEQ (a, T1, T1, 0); A_ADDI(a, T0, T0, 1);
    mxq_patch_b(a, fix, mxq_here(a));
    fix = mxq_here(a); A_BNE (a, T1, T1, 0); A_ADDI(a, T0, T0, 2);
    mxq_patch_b(a, fix, mxq_here(a));
    fix = mxq_here(a); A_BLT (a, T1, T2, 0); A_ADDI(a, T0, T0, 4);
    mxq_patch_b(a, fix, mxq_here(a));
    fix = mxq_here(a); A_BGE (a, T1, T2, 0); A_ADDI(a, T0, T0, 8);
    mxq_patch_b(a, fix, mxq_here(a));
    fix = mxq_here(a); A_BLTU(a, T1, T2, 0); A_ADDI(a, T0, T0, 16);
    mxq_patch_b(a, fix, mxq_here(a));
    fix = mxq_here(a); A_BGEU(a, T1, T2, 0); A_ADDI(a, T0, T0, 32);
    mxq_patch_b(a, fix, mxq_here(a));
    PUT(T0);

    A_LI(a, T3, 0); A_LI(a, T4, 10);
    loop = mxq_here(a);
    A_ADDI(a, T3, T3, 3);
    A_ADDI(a, T4, T4, -1);
    fix = mxq_here(a); A_BNE(a, T4, X0, 0); mxq_patch_b(a, fix, loop);
    PUT(T3);

    fix = mxq_here(a); A_JAL(a, RA, 0); mxq_patch_j(a, fix, sub_ent);
    PUT(A5);

    /* --- custom-0 -------------------------------------------------------- */
    A_LI(a, T0, 0xC0003F80u);            /* {hi = -2.0, lo = 1.0} as bf16    */
    A_MXAMAX(a, T2, T0, X0);                                   PUT(T2);
    A_MXSCALE(a, T3, T2, X0);                                  PUT(T3);
    A_MXQ4(a, T4, T0, T3);                                     PUT(T4);
    A_MXDQ(a, T5, T4, T3);                                     PUT(T5);
    A_LI(a, T0, 0x11223344u); A_LI(a, T1, 0xAAu);
    A_MXPK(a, T6, T0, T1);                                     PUT(T6);

    /* --- auipc against the address jal linked ---------------------------- */
    fix = mxq_here(a); A_JAL(a, RA, 0); mxq_patch_j(a, fix, mxq_here(a));
    A_AUIPC(a, T0, 0);
    A_SUB(a, T1, T0, RA);                                      PUT(T1);

    A_LI(a, T0, 0x0F0F0F0Fu); A_XORI(a, T1, T0, -1);           PUT(T1);
    A_LI(a, T0, 0xF8000000u); A_SRAI(a, T1, T0, 3);            PUT(T1);
    A_LI(a, T0, 1);           A_SLLI(a, T1, T0, 5);            PUT(T1);

    A_LI(a, A0, 0);
    A_ECALL(a);
#undef PUT
    if (slot != MXQ_ISA_SLOTS) {   /* the table and the program must agree   */
        fprintf(stderr, "isa test: %d slots stored, table has %d\n",
                slot, MXQ_ISA_SLOTS);
        exit(1);
    }
    return mxq_here(a);
}

/* =========================================================================
 * 6. trap programs - one per architectural fault
 *
 * Each does a little real work first, so the counters latched at the fault
 * are something the testbench has to get right rather than zero.
 * ========================================================================= */
int mxq_build_trap(uint32_t *img, int cap, int which)
{
    mxq_asm_t as, *a = &as;
    int loop;
    mxq_asm_init(a, img, cap);

    A_LI(a, T0, 7);
    A_ADDI(a, T0, T0, 5);
    A_SW(a, A0, T0, 0);                 /* one honest store first           */

    switch (which) {
    case MXQ_TRAP_ILLEGAL:
        /* custom-0 with an undefined funct3 - the unit must reject it       */
        mxq_r(a, MXQ_OP_CUSTOM, 0, 6, T1, T0, T0);
        break;
    case MXQ_TRAP_LOAD_ALIGN:
        A_ADDI(a, T1, A0, 2);
        A_LW(a, T2, T1, 0);
        break;
    case MXQ_TRAP_STORE_ALIGN:
        A_ADDI(a, T1, A0, 1);
        A_SH(a, T1, T0, 0);
        break;
    case MXQ_TRAP_LOAD_FAULT:
        A_MV(a, T1, A1);                /* a1 = first address past the RAM  */
        A_LW(a, T2, T1, 0);
        break;
    case MXQ_TRAP_STORE_FAULT:
        A_MV(a, T1, A1);
        A_SW(a, T1, T0, 0);
        break;
    case MXQ_TRAP_FETCH_FAULT:
        A_MV(a, T1, A2);                /* a2 = first address past the ROM  */
        A_JALR(a, X0, T1, 0);
        break;
    default:                            /* watchdog: never reaches ECALL    */
        loop = mxq_here(a);
        A_ADDI(a, T0, T0, 1);
        { int fix = mxq_here(a); A_BNE(a, T0, X0, 0);
          mxq_patch_b(a, fix, loop); }
        break;
    }
    A_ECALL(a);
    return mxq_here(a);
}
