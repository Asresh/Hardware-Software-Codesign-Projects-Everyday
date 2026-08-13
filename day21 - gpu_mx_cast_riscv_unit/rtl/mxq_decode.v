// ===========================================================================
// mxq_decode - RV32I instruction decode, purely combinational.
//
// Produces the immediate, the operand selects, the ALU operation and the flags
// the execute stage needs.  `illegal` is asserted for anything this core does
// not implement, including a reserved shift encoding and a SYSTEM instruction
// that is not exactly ECALL - the point of a trap is that it fires on the
// instruction that was actually fetched, not on the one that was intended.
// ===========================================================================
`include "mxq_defs.vh"

module mxq_decode (
    input  wire [31:0] insn,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [4:0]  rd,
    output wire [2:0]  f3,
    output reg  [31:0] imm,
    output reg  [3:0]  alu_op,
    output reg         src_a_pc,     // AUIPC
    output reg         src_b_imm,
    output reg         reg_we,
    output reg         is_branch,
    output reg         is_jal,
    output reg         is_jalr,
    output reg         is_load,
    output reg         is_store,
    output reg         is_custom,
    output reg         is_ecall,
    output reg         wb_pc4,       // JAL / JALR link value
    output reg         illegal
);
    wire [6:0] op = insn[6:0];
    wire [6:0] f7 = insn[31:25];

    assign rs1 = insn[19:15];
    assign rs2 = insn[24:20];
    assign rd  = insn[11:7];
    assign f3  = insn[14:12];

    wire [31:0] imm_i = {{20{insn[31]}}, insn[31:20]};
    wire [31:0] imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
    wire [31:0] imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25],
                         insn[11:8], 1'b0};
    wire [31:0] imm_u = {insn[31:12], 12'd0};
    wire [31:0] imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20],
                         insn[30:21], 1'b0};

    always @* begin
        imm       = imm_i;
        alu_op    = 4'b0000;
        src_a_pc  = 1'b0;
        src_b_imm = 1'b1;
        reg_we    = 1'b0;
        is_branch = 1'b0;
        is_jal    = 1'b0;
        is_jalr   = 1'b0;
        is_load   = 1'b0;
        is_store  = 1'b0;
        is_custom = 1'b0;
        is_ecall  = 1'b0;
        wb_pc4    = 1'b0;
        illegal   = 1'b0;

        case (op)
            `MXQ_OP_OPIMM: begin
                reg_we = 1'b1;
                alu_op = {(f3 == 3'b101) & f7[5], f3};
                if (f3 == 3'b001 && f7 != 7'd0)                 illegal = 1'b1;
                if (f3 == 3'b101 && f7 != 7'd0 && f7 != 7'h20)  illegal = 1'b1;
            end
            `MXQ_OP_OP: begin
                reg_we    = 1'b1;
                src_b_imm = 1'b0;
                alu_op    = {f7[5], f3};
                if (f7 != 7'd0 &&
                    !(f7 == 7'h20 && (f3 == 3'b000 || f3 == 3'b101)))
                    illegal = 1'b1;
            end
            `MXQ_OP_CUSTOM: begin
                reg_we    = 1'b1;
                is_custom = 1'b1;
                if (f7 != 7'd0) illegal = 1'b1;
            end
            `MXQ_OP_LUI: begin
                reg_we = 1'b1; imm = imm_u; alu_op = 4'b1111;
            end
            `MXQ_OP_AUIPC: begin
                reg_we = 1'b1; imm = imm_u; src_a_pc = 1'b1;
            end
            `MXQ_OP_JAL: begin
                reg_we = 1'b1; imm = imm_j; is_jal = 1'b1; wb_pc4 = 1'b1;
            end
            `MXQ_OP_JALR: begin
                reg_we = 1'b1; is_jalr = 1'b1; wb_pc4 = 1'b1;
                if (f3 != 3'b000) illegal = 1'b1;
            end
            `MXQ_OP_BRANCH: begin
                imm = imm_b; is_branch = 1'b1; src_b_imm = 1'b0;
                if (f3 == 3'b010 || f3 == 3'b011) illegal = 1'b1;
            end
            `MXQ_OP_LOAD: begin
                reg_we = 1'b1; is_load = 1'b1;
                if (f3 == 3'b011 || f3 == 3'b110 || f3 == 3'b111) illegal = 1'b1;
            end
            `MXQ_OP_STORE: begin
                imm = imm_s; is_store = 1'b1;
                if (f3 > 3'b010) illegal = 1'b1;
            end
            `MXQ_OP_SYSTEM: begin
                if (insn == 32'h0000_0073) is_ecall = 1'b1;
                else                       illegal  = 1'b1;
            end
            default: illegal = 1'b1;
        endcase
    end
endmodule
