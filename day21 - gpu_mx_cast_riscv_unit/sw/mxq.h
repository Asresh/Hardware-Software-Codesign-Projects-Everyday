/* ===========================================================================
 * mxq.h - Day 21: MX-cast custom functional unit on an RV32I core.
 *
 * One header shared by the host program, the golden model, the instruction-set
 * simulator, the kernel builders and the firmware driver.  rtl/mxq_defs.vh is a
 * hand-maintained Verilog mirror of this file; MXQ_REGMAP_CSUM below is
 * recomputed from the register offsets at run time by the host and read back
 * out of the hardware in simulation, so the two cannot drift apart silently.
 * ===========================================================================*/
#ifndef MXQ_H
#define MXQ_H

#include <stdint.h>

/* ---- geometry (overridable from the Makefile) ---------------------------- */
#ifndef MXQ_IMEM_W
#define MXQ_IMEM_W 12          /* log2 instruction words                     */
#endif
#ifndef MXQ_DMEM_W
#define MXQ_DMEM_W 12          /* log2 data words                            */
#endif
#ifndef MXQ_BLK
#define MXQ_BLK 32             /* elements per MX block (OCP MX spec: 32)    */
#endif

#define MXQ_IMEM_WORDS (1u << MXQ_IMEM_W)
#define MXQ_DMEM_WORDS (1u << MXQ_DMEM_W)

/* ---- MX element format: E2M1 ("FP4"), shared E8M0 scale ------------------ */
/* codes 0..7 are magnitudes {0, .5, 1, 1.5, 2, 3, 4, 6}, bit 3 is the sign.  */
#define MXQ_EMAX_ELEM 2        /* floor(log2(6)) - largest binade of E2M1     */
#define MXQ_CODE_MAX  7
#define MXQ_BF16_MAXF 0x7F7Fu  /* largest finite bf16 magnitude field         */

/* Q4.8 midpoints of the E2M1 grid, in units of 1/256.  Ties round to the even
 * code, which is what MXQ_RNE_EVEN[] holds. */
#define MXQ_NTHRESH 7
extern const uint16_t MXQ_THRESH[MXQ_NTHRESH];
extern const uint8_t  MXQ_RNE_EVEN[MXQ_NTHRESH];

/* ---- host-side register map (byte offsets) ------------------------------- */
#define MXQ_REG_CTRL         0x00u
#define MXQ_REG_STATUS       0x04u
#define MXQ_REG_IRQ_STAT     0x08u
#define MXQ_REG_ERRCODE      0x0Cu
#define MXQ_REG_START_PC     0x10u
#define MXQ_REG_WDOG         0x14u
#define MXQ_REG_CYCLES       0x18u
#define MXQ_REG_INSTRET      0x1Cu
#define MXQ_REG_CUSTOM_OPS   0x20u
#define MXQ_REG_BRANCH_TAKEN 0x24u
#define MXQ_REG_LOADS        0x28u
#define MXQ_REG_STORES       0x2Cu
#define MXQ_REG_TRAP_PC      0x30u
#define MXQ_REG_ARG0         0x34u
#define MXQ_REG_ARG1         0x38u
#define MXQ_REG_ARG2         0x3Cu
#define MXQ_REG_ARG3         0x40u
#define MXQ_REG_RETVAL       0x44u
#define MXQ_REG_HALT_PC      0x48u
#define MXQ_REG_CAPS         0x4Cu
#define MXQ_REG_VERSION      0x50u
#define MXQ_REG_REGMAP_CSUM  0x54u
#define MXQ_NREGS            22

/* windows in the host address space */
#define MXQ_WIN_IMEM 0x00010000u
#define MXQ_WIN_DMEM 0x00020000u

/* CTRL bits (all four write-only, the three action bits self-clear) */
#define MXQ_CTRL_START    (1u << 0)
#define MXQ_CTRL_IRQ_EN   (1u << 1)
#define MXQ_CTRL_SOFT_RST (1u << 2)
#define MXQ_CTRL_CLR_STAT (1u << 3)

/* STATUS bits */
#define MXQ_ST_RUNNING (1u << 0)
#define MXQ_ST_HALTED  (1u << 1)
#define MXQ_ST_TRAP    (1u << 2)

/* IRQ_STAT bits (write 1 to clear) */
#define MXQ_IRQ_DONE (1u << 0)
#define MXQ_IRQ_TRAP (1u << 1)

/* ERRCODE - 0 means the program reached ECALL cleanly */
#define MXQ_ERR_NONE        0u
#define MXQ_ERR_ILLEGAL     1u
#define MXQ_ERR_LOAD_ALIGN  2u
#define MXQ_ERR_STORE_ALIGN 3u
#define MXQ_ERR_LOAD_FAULT  4u
#define MXQ_ERR_STORE_FAULT 5u
#define MXQ_ERR_FETCH_FAULT 6u
#define MXQ_ERR_WDOG        7u

#define MXQ_VERSION_ID 0x00150001u   /* day 21, rev 1 */

/* ---- instruction encoding ------------------------------------------------ */
#define MXQ_OP_LOAD   0x03u
#define MXQ_OP_OPIMM  0x13u
#define MXQ_OP_AUIPC  0x17u
#define MXQ_OP_STORE  0x23u
#define MXQ_OP_OP     0x33u
#define MXQ_OP_LUI    0x37u
#define MXQ_OP_BRANCH 0x63u
#define MXQ_OP_JALR   0x67u
#define MXQ_OP_JAL    0x6Fu
#define MXQ_OP_SYSTEM 0x73u
#define MXQ_OP_CUSTOM 0x0Bu   /* custom-0 */

/* custom-0 funct3 assignments */
#define MXQ_F3_AMAX  0u   /* rd = max(|bf16 halves of rs1|, rs2)             */
#define MXQ_F3_SCALE 1u   /* rd = E8M0 shared scale for block amax rs1       */
#define MXQ_F3_Q4    2u   /* rd = two E2M1 codes from rs1 at scale rs2       */
#define MXQ_F3_DQ    3u   /* rd = two bf16 from the codes in rs1 at scale rs2*/
#define MXQ_F3_PK    4u   /* rd = (rs1 >> 8) | (rs2[7:0] << 24)              */
#define MXQ_NCUSTOM  5u

/* register ABI names used by the kernel builders */
enum { X0 = 0, RA = 1, SP = 2, GP = 3, TP = 4, T0 = 5, T1 = 6, T2 = 7,
       S0 = 8, S1 = 9, A0 = 10, A1 = 11, A2 = 12, A3 = 13, A4 = 14, A5 = 15,
       A6 = 16, A7 = 17, S2 = 18, S3 = 19, S4 = 20, S5 = 21, S6 = 22,
       S7 = 23, S8 = 24, S9 = 25, S10 = 26, S11 = 27, T3 = 28, T4 = 29,
       T5 = 30, T6 = 31 };

/* ---- pipeline timing model ----------------------------------------------- */
/* The core is a three-stage machine (F / X / W).  Every instruction retires in
 * one cycle; a taken branch or jump discards the one instruction already
 * fetched behind it, and MXQ_PIPE_FILL covers the start-up and the ECALL
 * drain.  CYCLES read back from the hardware must equal
 *     instret + branch_taken + MXQ_PIPE_FILL
 * on every job - the testbench checks it, which is how a stall that should not
 * exist becomes a failure rather than a slower number nobody looks at. */
#define MXQ_PIPE_FILL 2

/* ---- golden model (sw/mxq_model.c) --------------------------------------- */
uint16_t mxq_bf16_amax(const uint16_t *v, int n);
uint8_t  mxq_shared_scale(uint16_t amax_mag);
uint8_t  mxq_quant_elem(uint16_t bf16, uint8_t scale);
uint16_t mxq_dequant_elem(uint8_t code, uint8_t scale);
void     mxq_quant_block(const uint16_t *in, int n, uint8_t *scale, uint8_t *codes);
void     mxq_dequant_block(uint8_t scale, const uint8_t *codes, int n, uint16_t *out);
uint32_t mxq_regmap_csum(void);

/* ---- scalar baseline (sw/mxq_baseline.c) --------------------------------- */
typedef struct {
    uint64_t instr;      /* dynamic RV32I instructions, base ISA only        */
    uint64_t loads;
    uint64_t stores;
    uint64_t branches;   /* taken branches                                    */
} mxq_cost_t;
uint8_t  mxq_quant_elem_fp(uint16_t bf16, uint8_t scale);
double   mxq_dequant_value(uint8_t code, uint8_t scale);
void mxq_baseline_quant(const uint16_t *in, int nblk, int blk,
                        uint8_t *scales, uint8_t *codes, mxq_cost_t *cost);
void mxq_baseline_dequant(const uint8_t *scales, const uint8_t *codes,
                          int nblk, int blk, uint16_t *out, mxq_cost_t *cost);

/* ---- assembler (sw/mxq_asm.c) -------------------------------------------- */
typedef struct {
    uint32_t *code;
    int       n;
    int       cap;
} mxq_asm_t;

void mxq_asm_init(mxq_asm_t *a, uint32_t *buf, int cap);
int  mxq_here(const mxq_asm_t *a);              /* next slot, in words        */
void mxq_patch_j(mxq_asm_t *a, int at, int target);
void mxq_patch_b(mxq_asm_t *a, int at, int target);

void mxq_r(mxq_asm_t *a, uint32_t op, uint32_t f7, uint32_t f3, int rd, int rs1, int rs2);
void mxq_i(mxq_asm_t *a, uint32_t op, uint32_t f3, int rd, int rs1, int32_t imm);
void mxq_s(mxq_asm_t *a, uint32_t f3, int rs1, int rs2, int32_t imm);
void mxq_b(mxq_asm_t *a, uint32_t f3, int rs1, int rs2, int32_t off);
void mxq_u(mxq_asm_t *a, uint32_t op, int rd, uint32_t imm20);
void mxq_j(mxq_asm_t *a, int rd, int32_t off);

/* ---- instruction-set simulator (sw/mxq_iss.c) ---------------------------- */
typedef struct {
    uint32_t pc;
    uint32_t code;       /* {store:1, load:1, rd:5} packed - see mxq_iss.c   */
    uint32_t wdata;
    uint32_t addr;
    uint32_t sdata;
} mxq_commit_t;

typedef struct {
    uint32_t x[32];
    uint32_t pc;
    uint32_t halted, trapped, errcode, trap_pc, halt_pc;
    uint64_t instret, custom_ops, branch_taken, loads, stores, cycles;
    mxq_commit_t *trace;
    int       ntrace, cap_trace;
} mxq_iss_t;

#define MXQ_CM_RD(c)    ((c) & 0x1Fu)
#define MXQ_CM_LOAD     (1u << 5)
#define MXQ_CM_STORE    (1u << 6)
#define MXQ_CM_WEN      (1u << 7)

void mxq_iss_run(mxq_iss_t *s, const uint32_t *imem, uint32_t imem_words,
                 uint32_t *dmem, uint32_t dmem_words, uint32_t wdog);

/* ---- kernel builders (sw/mxq_kernels.c) ---------------------------------- */
/* Every kernel takes a0 = input word address, a1 = output word address,
 * a2 = number of blocks, a3 = block size, and returns a0 = blocks done. */
int mxq_build_quant_custom(uint32_t *img, int cap);
int mxq_build_quant_base(uint32_t *img, int cap);
int mxq_build_dequant_custom(uint32_t *img, int cap);
int mxq_build_dequant_base(uint32_t *img, int cap);
int mxq_build_isa_test(uint32_t *img, int cap);   /* a0 = out, a1 = scratch */
int mxq_build_trap(uint32_t *img, int cap, int which);

/* the values sw/mxq_host.c requires the ISA test to leave in memory - written
 * out by hand, so the simulator and the core are not each other's only
 * witness */
#define MXQ_ISA_SLOTS 33
extern const uint32_t MXQ_ISA_EXPECT[MXQ_ISA_SLOTS];

enum { MXQ_TRAP_ILLEGAL = 0, MXQ_TRAP_LOAD_ALIGN, MXQ_TRAP_STORE_ALIGN,
       MXQ_TRAP_LOAD_FAULT, MXQ_TRAP_STORE_FAULT, MXQ_TRAP_FETCH_FAULT,
       MXQ_TRAP_WDOG, MXQ_TRAP_N };

/* checksum constant - must equal mxq_regmap_csum(); mirrored in mxq_defs.vh */
#define MXQ_REGMAP_CSUM 0x0001985Au

#endif /* MXQ_H */
