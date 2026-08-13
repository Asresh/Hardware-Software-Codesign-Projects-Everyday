// ===========================================================================
// mxq_core - three-stage RV32I pipeline with the MX unit in its execute stage.
//
//   F : present the PC to the instruction memory
//   X : decode, read the registers, execute (ALU, branch, MX unit), present
//       the data address
//   W : select the writeback value and commit it
//
// One instruction retires per cycle.  There is no load-use stall: a load's
// data leaves the memory at the top of the W cycle, which is the same cycle
// the consumer is in X, so the single W->X bypass covers it - the cost is that
// the SRAM output sits in front of the ALU, which is this design's critical
// path and is called out as such rather than hidden.  The only bubble in the
// machine is the one instruction already fetched behind a taken branch, so
//
//     cycles = instructions retired + taken branches + 2
//
// exactly, always - the two being the fill of F/X at the start and the drain
// of W at the end.  The testbench checks that identity on every job, which is
// what turns "the pipeline stalled somewhere it should not have" from a
// slightly worse number into a failure.
//
// Traps are precise and prioritised: watchdog, then fetch, then illegal
// instruction, then misalignment, then address range.  A trapping instruction
// does not retire, does not write a register and does not touch memory.
// ===========================================================================
`include "mxq_defs.vh"

module mxq_core #(
    parameter IMEM_W = 12,
    parameter DMEM_W = 12
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [31:0] start_pc,
    input  wire [31:0] wdog,
    input  wire [31:0] arg0,
    input  wire [31:0] arg1,
    input  wire [31:0] arg2,
    input  wire [31:0] arg3,

    output reg         running,
    output reg         halted,
    output reg         trapped,
    output reg  [3:0]  errcode,
    output reg  [31:0] trap_pc,
    output reg  [31:0] halt_pc,
    output wire [31:0] retval,

    output reg  [31:0] c_cycles,
    output reg  [31:0] c_instret,
    output reg  [31:0] c_custom,
    output reg  [31:0] c_branch,
    output reg  [31:0] c_loads,
    output reg  [31:0] c_stores,

    output wire [IMEM_W-1:0] im_addr,
    output wire              im_en,
    input  wire [31:0]       im_rdata,

    output wire [DMEM_W-1:0] dm_addr,
    output wire              dm_en,
    output wire              dm_we,
    output wire [3:0]        dm_be,
    output wire [31:0]       dm_wdata,
    input  wire [31:0]       dm_rdata,

    output wire        dbg_valid,
    output wire [31:0] dbg_pc,
    output wire [7:0]  dbg_code,
    output wire [31:0] dbg_wdata,
    output wire [31:0] dbg_addr,
    output wire [31:0] dbg_sdata
);
    // ---- fetch ------------------------------------------------------------
    reg  [31:0] pc_f, pc_x;
    reg         valid_f, valid_x, ff_x;
    wire        ff_f = (|pc_f[1:0]) | (|pc_f[31:IMEM_W+2]);

    assign im_addr = pc_f[IMEM_W+1:2];
    assign im_en   = running;

    // ---- decode -----------------------------------------------------------
    wire [31:0] insn = im_rdata;
    wire [4:0]  rs1, rs2, rd;
    wire [2:0]  f3;
    wire [31:0] imm;
    wire [3:0]  alu_op;
    wire        src_a_pc, src_b_imm, reg_we, is_branch, is_jal, is_jalr;
    wire        is_load, is_store, is_custom, is_ecall, wb_pc4, illegal;

    mxq_decode u_dec (
        .insn(insn), .rs1(rs1), .rs2(rs2), .rd(rd), .f3(f3), .imm(imm),
        .alu_op(alu_op), .src_a_pc(src_a_pc), .src_b_imm(src_b_imm),
        .reg_we(reg_we), .is_branch(is_branch), .is_jal(is_jal),
        .is_jalr(is_jalr), .is_load(is_load), .is_store(is_store),
        .is_custom(is_custom), .is_ecall(is_ecall), .wb_pc4(wb_pc4),
        .illegal(illegal)
    );

    // ---- writeback stage registers ---------------------------------------
    reg         w_valid, w_we, w_is_load, w_halt;
    reg  [4:0]  w_rd;
    reg  [2:0]  w_f3;
    reg  [1:0]  w_alow;
    reg  [31:0] w_result, w_pc, w_maddr, w_sdata;
    reg  [7:0]  w_code;

    function [31:0] ldext;
        input [31:0] w;
        input [2:0]  f3i;
        input [1:0]  a;
        reg [7:0]  bsel;
        reg [15:0] hsel;
        begin
            case (a)
                2'd0: bsel = w[7:0];
                2'd1: bsel = w[15:8];
                2'd2: bsel = w[23:16];
                default: bsel = w[31:24];
            endcase
            hsel = a[1] ? w[31:16] : w[15:0];
            case (f3i)
                3'b000:  ldext = {{24{bsel[7]}},  bsel};
                3'b001:  ldext = {{16{hsel[15]}}, hsel};
                3'b100:  ldext = {24'd0, bsel};
                3'b101:  ldext = {16'd0, hsel};
                default: ldext = w;
            endcase
        end
    endfunction

    wire [31:0] wb_data = w_is_load ? ldext(dm_rdata, w_f3, w_alow) : w_result;

    // ---- register file and the one bypass --------------------------------
    reg         arg_we;
    wire [31:0] rf1, rf2;

    mxq_regfile u_rf (
        .clk(clk), .rst_n(rst_n), .ra1(rs1), .ra2(rs2), .rd1(rf1), .rd2(rf2),
        .we(w_valid & w_we), .wa(w_rd), .wd(wb_data),
        .arg_we(arg_we), .arg0(arg0), .arg1(arg1), .arg2(arg2), .arg3(arg3),
        .x10(retval)
    );

    wire fwd1 = w_valid & w_we & (w_rd == rs1);
    wire fwd2 = w_valid & w_we & (w_rd == rs2);
    wire [31:0] op1 = (rs1 == 5'd0) ? 32'd0 : (fwd1 ? wb_data : rf1);
    wire [31:0] op2 = (rs2 == 5'd0) ? 32'd0 : (fwd2 ? wb_data : rf2);

    // ---- execute ----------------------------------------------------------
    wire [31:0] alu_a = src_a_pc  ? pc_x : op1;
    wire [31:0] alu_b = src_b_imm ? imm  : op2;
    wire [31:0] alu_y;
    wire        br_take;

    mxq_alu u_alu (
        .op(alu_op), .a(alu_a), .b(alu_b), .y(alu_y),
        .br_f3(f3), .br_take(br_take)
    );

    wire [31:0] mx_out;
    wire        mx_legal;
    mxq_mx_unit u_mx (
        .f3(f3), .rs1(op1), .rs2(op2), .out(mx_out), .legal(mx_legal)
    );

    // ---- memory access ----------------------------------------------------
    wire [31:0] mem_addr = alu_y;
    wire        mem_oob  = |mem_addr[31:DMEM_W+2];
    wire        half_ma  = mem_addr[0];
    wire        word_ma  = |mem_addr[1:0];

    wire ld_align_bad = is_load  & (((f3 == 3'b001 || f3 == 3'b101) & half_ma)
                                  | ((f3 == 3'b010) & word_ma));
    wire st_align_bad = is_store & (((f3 == 3'b001) & half_ma)
                                  | ((f3 == 3'b010) & word_ma));

    wire wdog_hit = (wdog != 32'd0) && (c_instret >= wdog);
    wire ill_x    = illegal | (is_custom & ~mx_legal);

    reg [3:0] cause;
    always @* begin
        if      (wdog_hit)     cause = `MXQ_ERR_WDOG;
        else if (ff_x)         cause = `MXQ_ERR_FETCH_FAULT;
        else if (ill_x)        cause = `MXQ_ERR_ILLEGAL;
        else if (ld_align_bad) cause = `MXQ_ERR_LOAD_ALIGN;
        else if (st_align_bad) cause = `MXQ_ERR_STORE_ALIGN;
        else if (is_load  & mem_oob) cause = `MXQ_ERR_LOAD_FAULT;
        else if (is_store & mem_oob) cause = `MXQ_ERR_STORE_FAULT;
        else                   cause = `MXQ_ERR_NONE;
    end

    wire x_trap = valid_x & (cause != `MXQ_ERR_NONE);
    wire x_go   = valid_x & ~x_trap;
    wire x_mem  = x_go & (is_load | is_store);

    assign dm_addr  = mem_addr[DMEM_W+1:2];
    assign dm_en    = x_mem;
    assign dm_we    = x_go & is_store;
    assign dm_be    = (f3 == 3'b000) ? (4'b0001 << mem_addr[1:0]) :
                      (f3 == 3'b001) ? (mem_addr[1] ? 4'b1100 : 4'b0011) :
                                       4'b1111;
    assign dm_wdata = (f3 == 3'b000) ? {4{op2[7:0]}} :
                      (f3 == 3'b001) ? {2{op2[15:0]}} : op2;

    wire [31:0] sdata_x = (f3 == 3'b000) ? {24'd0, op2[7:0]} :
                          (f3 == 3'b001) ? {16'd0, op2[15:0]} : op2;

    // ---- next PC ----------------------------------------------------------
    wire        redirect = x_go & ((is_branch & br_take) | is_jal | is_jalr);
    wire [31:0] target   = is_jalr ? ((op1 + imm) & 32'hFFFF_FFFE)
                                   : (pc_x + imm);

    wire [31:0] x_result = wb_pc4    ? (pc_x + 32'd4) :
                           is_custom ? mx_out : alu_y;
    wire        x_regwe  = reg_we & (rd != 5'd0);
    wire [7:0]  x_code   = (is_load  ? 8'h20 : 8'h00)
                         | (is_store ? 8'h40 : 8'h00)
                         | (x_regwe  ? (8'h80 | {3'd0, rd}) : 8'h00);

    // ---- debug commit port ------------------------------------------------
    assign dbg_valid = w_valid;
    assign dbg_pc    = w_pc;
    assign dbg_code  = w_code;
    assign dbg_wdata = w_we ? wb_data : 32'd0;
    assign dbg_addr  = w_maddr;
    assign dbg_sdata = w_sdata;

    // ---- sequencing -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0; halted <= 1'b0; trapped <= 1'b0;
            errcode <= `MXQ_ERR_NONE; trap_pc <= 32'd0; halt_pc <= 32'd0;
            pc_f <= 32'd0; pc_x <= 32'd0;
            valid_f <= 1'b0; valid_x <= 1'b0; ff_x <= 1'b0;
            w_valid <= 1'b0; w_we <= 1'b0; w_is_load <= 1'b0; w_halt <= 1'b0;
            w_rd <= 5'd0; w_f3 <= 3'd0; w_alow <= 2'd0;
            w_result <= 32'd0; w_pc <= 32'd0; w_maddr <= 32'd0;
            w_sdata <= 32'd0; w_code <= 8'd0;
            c_cycles <= 32'd0; c_instret <= 32'd0; c_custom <= 32'd0;
            c_branch <= 32'd0; c_loads <= 32'd0; c_stores <= 32'd0;
            arg_we <= 1'b0;
        end else begin
            arg_we <= 1'b0;

            if (start && !running) begin
                running   <= 1'b1;
                halted    <= 1'b0;
                trapped   <= 1'b0;
                errcode   <= `MXQ_ERR_NONE;
                trap_pc   <= 32'd0;
                halt_pc   <= 32'd0;
                pc_f      <= start_pc;
                valid_f   <= 1'b1;
                valid_x   <= 1'b0;
                ff_x      <= 1'b0;
                w_valid   <= 1'b0;
                w_halt    <= 1'b0;
                arg_we    <= 1'b1;
                c_cycles  <= 32'd0; c_instret <= 32'd0; c_custom <= 32'd0;
                c_branch  <= 32'd0; c_loads   <= 32'd0; c_stores <= 32'd0;
            end else if (running) begin
                c_cycles <= c_cycles + 32'd1;

                if (w_halt) begin
                    // the ECALL has now retired out of W: stop
                    running <= 1'b0;
                    halted  <= 1'b1;
                    halt_pc <= w_pc;
                    w_valid <= 1'b0;
                    w_halt  <= 1'b0;
                end else if (x_trap) begin
                    running <= 1'b0;
                    halted  <= 1'b1;
                    trapped <= 1'b1;
                    errcode <= cause;
                    trap_pc <= pc_x;
                    valid_x <= 1'b0;
                    valid_f <= 1'b0;
                    w_valid <= 1'b0;
                end else begin
                    // ---- W stage load ---------------------------------
                    w_valid   <= valid_x;
                    w_we      <= x_regwe;
                    w_rd      <= rd;
                    w_result  <= x_result;
                    w_is_load <= is_load;
                    w_f3      <= f3;
                    w_alow    <= mem_addr[1:0];
                    w_pc      <= pc_x;
                    w_code    <= x_code;
                    w_maddr   <= (is_load | is_store) ? mem_addr : 32'd0;
                    w_sdata   <= is_store ? sdata_x : 32'd0;

                    // ---- counters --------------------------------------
                    if (x_go) begin
                        c_instret <= c_instret + 32'd1;
                        if (is_custom) c_custom <= c_custom + 32'd1;
                        if ((is_branch & br_take) | is_jal | is_jalr)
                            c_branch <= c_branch + 32'd1;
                        if (is_load)  c_loads  <= c_loads  + 32'd1;
                        if (is_store) c_stores <= c_stores + 32'd1;
                    end

                    // ---- F/X advance -----------------------------------
                    if (x_go & is_ecall) begin
                        w_halt  <= 1'b1;
                        valid_x <= 1'b0;
                        valid_f <= 1'b0;
                    end else begin
                        pc_x    <= pc_f;
                        ff_x    <= ff_f;
                        valid_x <= valid_f & ~redirect;
                        pc_f    <= redirect ? target : (pc_f + 32'd4);
                    end
                end
            end
        end
    end
endmodule
