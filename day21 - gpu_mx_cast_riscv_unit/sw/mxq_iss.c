/* ===========================================================================
 * mxq_iss.c - instruction-set simulator for the RV32I core and its custom-0
 * unit, and the source of the commit trace the testbench compares against.
 *
 * The trace is the point.  Checking that a core produced the right answer in
 * memory catches a broken kernel; checking every architectural write it made,
 * in order, catches a broken *core* - a forward that fires a cycle late, a
 * branch that flushes the wrong instruction, a byte store that merges the
 * wrong lane - on the first instruction that exposes it rather than on the
 * one in ten thousand whose result happens to survive.
 *
 * Cycles are modelled rather than counted, from the microarchitecture: three
 * stages, one retirement per cycle, one discarded fetch behind every taken
 * branch.  The testbench compares that model against the hardware's own
 * counter on every job, so the model is a claim about the pipeline and not a
 * restatement of it.
 * ===========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mxq.h"

static uint32_t sext(uint32_t v, int bits_used)
{
    uint32_t m = 1u << (bits_used - 1);
    return (v ^ m) - m;
}

static uint32_t srl_u(uint32_t v, uint32_t sh) { return v >> (sh & 31u); }
static uint32_t sll_u(uint32_t v, uint32_t sh) { return v << (sh & 31u); }
/* arithmetic shift written without a signed shift, so it means the same thing
 * on every compiler the generator is ever built with */
static uint32_t sra_u(uint32_t v, uint32_t sh)
{
    uint32_t s = sh & 31u;
    uint32_t r = v >> s;
    if (v & 0x80000000u) r |= ~(0xFFFFFFFFu >> s);
    return r;
}

/* ---- the custom-0 functional unit, in software --------------------------- */
static uint32_t mx_amax(uint32_t rs1, uint32_t rs2)
{
    uint16_t v[2];
    uint16_t acc = (uint16_t)(rs2 & 0x7FFFu);
    uint16_t m;
    v[0] = (uint16_t)(rs1 & 0xFFFFu);
    v[1] = (uint16_t)(rs1 >> 16);
    m = mxq_bf16_amax(v, 2);
    return (uint32_t)(m > acc ? m : acc);
}

static uint32_t mx_q4(uint32_t rs1, uint32_t rs2)
{
    uint8_t sc = (uint8_t)(rs2 & 0xFFu);
    uint32_t lo = mxq_quant_elem((uint16_t)(rs1 & 0xFFFFu), sc);
    uint32_t hi = mxq_quant_elem((uint16_t)(rs1 >> 16), sc);
    return (hi << 4) | lo;
}

static uint32_t mx_dq(uint32_t rs1, uint32_t rs2)
{
    uint8_t sc = (uint8_t)(rs2 & 0xFFu);
    uint32_t lo = mxq_dequant_elem((uint8_t)(rs1 & 0xFu), sc);
    uint32_t hi = mxq_dequant_elem((uint8_t)((rs1 >> 4) & 0xFu), sc);
    return (hi << 16) | lo;
}

uint32_t mxq_custom_exec(uint32_t f3, uint32_t rs1, uint32_t rs2, int *legal)
{
    *legal = 1;
    switch (f3) {
    case MXQ_F3_AMAX:  return mx_amax(rs1, rs2);
    case MXQ_F3_SCALE: return mxq_shared_scale((uint16_t)(rs1 & 0x7FFFu));
    case MXQ_F3_Q4:    return mx_q4(rs1, rs2);
    case MXQ_F3_DQ:    return mx_dq(rs1, rs2);
    case MXQ_F3_PK:    return (rs1 >> 8) | ((rs2 & 0xFFu) << 24);
    default: *legal = 0; return 0;
    }
}

/* ---- trace ---------------------------------------------------------------*/
static void emit(mxq_iss_t *s, uint32_t pc, uint32_t code, uint32_t wdata,
                 uint32_t addr, uint32_t sdata)
{
    if (s->trace && s->ntrace < s->cap_trace) {
        mxq_commit_t *c = &s->trace[s->ntrace];
        c->pc = pc; c->code = code; c->wdata = wdata;
        c->addr = addr; c->sdata = sdata;
    }
    s->ntrace++;
}

static void take_trap(mxq_iss_t *s, uint32_t code, uint32_t pc)
{
    s->trapped = 1; s->halted = 1; s->errcode = code; s->trap_pc = pc;
}

void mxq_iss_run(mxq_iss_t *s, const uint32_t *imem, uint32_t imem_words,
                 uint32_t *dmem, uint32_t dmem_words, uint32_t wdog)
{
    uint32_t dbytes = dmem_words * 4u;

    s->halted = s->trapped = s->errcode = 0;
    s->trap_pc = s->halt_pc = 0;
    s->instret = s->custom_ops = s->branch_taken = s->loads = s->stores = 0;
    s->ntrace = 0;
    s->x[0] = 0;

    while (!s->halted) {
        uint32_t pc = s->pc, insn, op, rd, rs1, rs2, f3, f7;
        uint32_t a, b, res = 0, code = 0, maddr = 0, sdata = 0;
        uint32_t next = pc + 4u;
        int wen = 0;

        if (wdog && s->instret >= wdog) { take_trap(s, MXQ_ERR_WDOG, pc); break; }
        if ((pc & 3u) || (pc >> 2) >= imem_words) {
            take_trap(s, MXQ_ERR_FETCH_FAULT, pc); break;
        }

        insn = imem[pc >> 2];
        op  = insn & 0x7Fu;
        rd  = (insn >> 7) & 0x1Fu;
        f3  = (insn >> 12) & 7u;
        rs1 = (insn >> 15) & 0x1Fu;
        rs2 = (insn >> 20) & 0x1Fu;
        f7  = insn >> 25;
        a   = s->x[rs1];
        b   = s->x[rs2];

        switch (op) {
        case MXQ_OP_OPIMM: {
            uint32_t imm = sext(insn >> 20, 12);
            switch (f3) {
            case 0: res = a + imm; break;
            case 1: if (f7 != 0) { take_trap(s, MXQ_ERR_ILLEGAL, pc); }
                    res = sll_u(a, rs2); break;
            case 2: res = ((int32_t)a < (int32_t)imm) ? 1u : 0u; break;
            case 3: res = (a < imm) ? 1u : 0u; break;
            case 4: res = a ^ imm; break;
            case 5: if (f7 == 0x20u)      res = sra_u(a, rs2);
                    else if (f7 == 0u)    res = srl_u(a, rs2);
                    else { take_trap(s, MXQ_ERR_ILLEGAL, pc); }
                    break;
            case 6: res = a | imm; break;
            default: res = a & imm; break;
            }
            wen = 1; break;
        }
        case MXQ_OP_OP:
            if (f7 != 0u && !(f7 == 0x20u && (f3 == 0u || f3 == 5u))) {
                take_trap(s, MXQ_ERR_ILLEGAL, pc); break;
            }
            switch (f3) {
            case 0: res = (f7 == 0x20u) ? a - b : a + b; break;
            case 1: res = sll_u(a, b); break;
            case 2: res = ((int32_t)a < (int32_t)b) ? 1u : 0u; break;
            case 3: res = (a < b) ? 1u : 0u; break;
            case 4: res = a ^ b; break;
            case 5: res = (f7 == 0x20u) ? sra_u(a, b) : srl_u(a, b); break;
            case 6: res = a | b; break;
            default: res = a & b; break;
            }
            wen = 1; break;
        case MXQ_OP_CUSTOM: {
            int legal;
            if (f7 != 0u) { take_trap(s, MXQ_ERR_ILLEGAL, pc); break; }
            res = mxq_custom_exec(f3, a, b, &legal);
            if (!legal) { take_trap(s, MXQ_ERR_ILLEGAL, pc); break; }
            s->custom_ops++;
            wen = 1; break;
        }
        case MXQ_OP_LUI:   res = insn & 0xFFFFF000u; wen = 1; break;
        case MXQ_OP_AUIPC: res = pc + (insn & 0xFFFFF000u); wen = 1; break;
        case MXQ_OP_JAL: {
            uint32_t imm = sext(((insn >> 31) << 20) |
                                (((insn >> 12) & 0xFFu) << 12) |
                                (((insn >> 20) & 1u) << 11) |
                                (((insn >> 21) & 0x3FFu) << 1), 21);
            res = pc + 4u; wen = 1; next = pc + imm;
            s->branch_taken++;
            break;
        }
        case MXQ_OP_JALR: {
            uint32_t imm = sext(insn >> 20, 12);
            if (f3 != 0u) { take_trap(s, MXQ_ERR_ILLEGAL, pc); break; }
            res = pc + 4u; wen = 1; next = (a + imm) & ~1u;
            s->branch_taken++;
            break;
        }
        case MXQ_OP_BRANCH: {
            uint32_t imm = sext(((insn >> 31) << 12) |
                                (((insn >> 7) & 1u) << 11) |
                                (((insn >> 25) & 0x3Fu) << 5) |
                                (((insn >> 8) & 0xFu) << 1), 13);
            int t;
            switch (f3) {
            case 0: t = (a == b); break;
            case 1: t = (a != b); break;
            case 4: t = ((int32_t)a <  (int32_t)b); break;
            case 5: t = ((int32_t)a >= (int32_t)b); break;
            case 6: t = (a <  b); break;
            case 7: t = (a >= b); break;
            default: take_trap(s, MXQ_ERR_ILLEGAL, pc); t = 0; break;
            }
            if (s->trapped) break;
            if (t) { next = pc + imm; s->branch_taken++; }
            break;
        }
        case MXQ_OP_LOAD: {
            uint32_t imm = sext(insn >> 20, 12);
            uint32_t ad  = a + imm;
            uint32_t w, sh;
            if (f3 == 3u || f3 == 6u || f3 == 7u) {
                take_trap(s, MXQ_ERR_ILLEGAL, pc); break;
            }
            if (((f3 == 1u || f3 == 5u) && (ad & 1u)) ||
                ((f3 == 2u) && (ad & 3u))) {
                take_trap(s, MXQ_ERR_LOAD_ALIGN, pc); break;
            }
            if (ad >= dbytes) { take_trap(s, MXQ_ERR_LOAD_FAULT, pc); break; }
            w  = dmem[ad >> 2];
            sh = (ad & 3u) * 8u;
            switch (f3) {
            case 0: res = sext((w >> sh) & 0xFFu, 8); break;
            case 1: res = sext((w >> ((ad & 2u) * 8u)) & 0xFFFFu, 16); break;
            case 2: res = w; break;
            case 4: res = (w >> sh) & 0xFFu; break;
            default: res = (w >> ((ad & 2u) * 8u)) & 0xFFFFu; break;
            }
            wen = 1; s->loads++;
            code |= MXQ_CM_LOAD; maddr = ad;
            break;
        }
        case MXQ_OP_STORE: {
            uint32_t imm = sext((((insn >> 25) & 0x7Fu) << 5) |
                                ((insn >> 7) & 0x1Fu), 12);
            uint32_t ad = a + imm, w, sh, mask;
            if (f3 > 2u) { take_trap(s, MXQ_ERR_ILLEGAL, pc); break; }
            if ((f3 == 1u && (ad & 1u)) || (f3 == 2u && (ad & 3u))) {
                take_trap(s, MXQ_ERR_STORE_ALIGN, pc); break;
            }
            if (ad >= dbytes) { take_trap(s, MXQ_ERR_STORE_FAULT, pc); break; }
            w  = dmem[ad >> 2];
            sh = (ad & 3u) * 8u;
            if (f3 == 0u)      { mask = 0xFFu << sh;   sdata = b & 0xFFu; }
            else if (f3 == 1u) { sh = (ad & 2u) * 8u;  mask = 0xFFFFu << sh;
                                 sdata = b & 0xFFFFu; }
            else               { sh = 0u; mask = 0xFFFFFFFFu; sdata = b; }
            dmem[ad >> 2] = (w & ~mask) | ((sdata << sh) & mask);
            s->stores++;
            code |= MXQ_CM_STORE; maddr = ad;
            break;
        }
        case MXQ_OP_SYSTEM:
            if (insn == 0x00000073u) { s->halted = 1; s->halt_pc = pc; }
            else take_trap(s, MXQ_ERR_ILLEGAL, pc);
            break;
        default:
            take_trap(s, MXQ_ERR_ILLEGAL, pc);
            break;
        }

        if (s->trapped) break;

        if (wen && rd != 0u) { s->x[rd] = res; code |= MXQ_CM_WEN | rd; }
        else if (wen)        { res = 0u; }
        else                 { res = 0u; }

        emit(s, pc, code, (code & MXQ_CM_WEN) ? s->x[rd] : 0u, maddr, sdata);
        s->instret++;

        if (s->halted) break;          /* ECALL retires, then stops */
        s->pc = next;
    }

    s->cycles = s->instret + s->branch_taken + MXQ_PIPE_FILL;
}
