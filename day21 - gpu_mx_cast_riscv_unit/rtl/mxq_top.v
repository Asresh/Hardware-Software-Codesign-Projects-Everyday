// ===========================================================================
// mxq_top - core, memories, control plane.
//
// The host sees one address space: registers at 0x0_0000, the instruction
// memory at 0x1_0000, the data memory at 0x2_0000.  Both memories are single
// ported and owned by the core while it runs, so a host access during
// execution reads zero and writes nothing rather than corrupting a program
// mid-flight; the driver has no reason to do it and the testbench proves what
// happens if it does.
//
// The bus is deliberately the dullest thing here - one selected/ready
// handshake, one wait state - because the interesting timing in this design is
// entirely inside the core, and the point of the two testbench passes is that
// nothing the host does to the bus can change what the program computes.
// ===========================================================================
`include "mxq_defs.vh"

module mxq_top #(
    parameter IMEM_W = `MXQ_IMEM_W,
    parameter DMEM_W = `MXQ_DMEM_W
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        h_sel,
    input  wire        h_we,
    input  wire [19:0] h_addr,
    input  wire [31:0] h_wdata,
    output reg  [31:0] h_rdata,
    output wire        h_ready,

    output wire        irq,

    // commit trace, for verification only
    output wire        dbg_valid,
    output wire [31:0] dbg_pc,
    output wire [7:0]  dbg_code,
    output wire [31:0] dbg_wdata,
    output wire [31:0] dbg_addr,
    output wire [31:0] dbg_sdata
);
    // ---- host handshake ---------------------------------------------------
    reg  ready_q;
    wire acc = h_sel & ~ready_q;
    assign h_ready = ready_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ready_q <= 1'b0;
        else        ready_q <= h_sel & ~ready_q;
    end

    wire [3:0] win     = h_addr[19:16];
    wire       is_regs = (win == `MXQ_WIN_REGS);
    wire       is_imem = (win == `MXQ_WIN_IMEM);
    wire       is_dmem = (win == `MXQ_WIN_DMEM);

    // ---- control plane ----------------------------------------------------
    wire        start, soft_rst;
    wire [31:0] start_pc, wdog, arg0, arg1, arg2, arg3;
    wire        running, halted, trapped;
    wire [3:0]  errcode;
    wire [31:0] trap_pc, halt_pc, retval;
    wire [31:0] c_cycles, c_instret, c_custom, c_branch, c_loads, c_stores;
    wire [31:0] reg_rdata;

    mxq_csr #(.IMEM_W(IMEM_W), .DMEM_W(DMEM_W)) u_csr (
        .clk(clk), .rst_n(rst_n),
        .acc(acc & is_regs), .we(h_we), .raddr(h_addr[7:2]), .wdata(h_wdata),
        .rdata(reg_rdata),
        .start(start), .start_pc(start_pc), .wdog(wdog),
        .arg0(arg0), .arg1(arg1), .arg2(arg2), .arg3(arg3),
        .soft_rst(soft_rst),
        .running(running), .halted(halted), .trapped(trapped),
        .errcode(errcode), .trap_pc(trap_pc), .halt_pc(halt_pc),
        .retval(retval),
        .c_cycles(c_cycles), .c_instret(c_instret), .c_custom(c_custom),
        .c_branch(c_branch), .c_loads(c_loads), .c_stores(c_stores),
        .irq(irq)
    );

    wire core_rst_n = rst_n & ~soft_rst;

    // ---- memories ---------------------------------------------------------
    wire [IMEM_W-1:0] core_im_addr;
    wire              core_im_en;
    wire [31:0]       im_rdata;

    wire [DMEM_W-1:0] core_dm_addr;
    wire              core_dm_en, core_dm_we;
    wire [3:0]        core_dm_be;
    wire [31:0]       core_dm_wdata, dm_rdata;

    wire host_mem = acc & ~running;
    wire h_im_en  = host_mem & is_imem;
    wire h_dm_en  = host_mem & is_dmem;

    wire              im_en    = running ? core_im_en : h_im_en;
    wire              im_we    = running ? 1'b0       : (h_im_en & h_we);
    wire [IMEM_W-1:0] im_addr  = running ? core_im_addr : h_addr[IMEM_W+1:2];

    wire              dm_en    = running ? core_dm_en : h_dm_en;
    wire              dm_we    = running ? core_dm_we : (h_dm_en & h_we);
    wire [3:0]        dm_be    = running ? core_dm_be : 4'b1111;
    wire [DMEM_W-1:0] dm_addr  = running ? core_dm_addr : h_addr[DMEM_W+1:2];
    wire [31:0]       dm_wdata = running ? core_dm_wdata : h_wdata;

    mxq_sram #(.AW(IMEM_W)) u_imem (
        .clk(clk), .en(im_en), .we(im_we), .be(4'b1111), .addr(im_addr),
        .wdata(h_wdata), .rdata(im_rdata)
    );

    mxq_sram #(.AW(DMEM_W)) u_dmem (
        .clk(clk), .en(dm_en), .we(dm_we), .be(dm_be), .addr(dm_addr),
        .wdata(dm_wdata), .rdata(dm_rdata)
    );

    // ---- core -------------------------------------------------------------
    mxq_core #(.IMEM_W(IMEM_W), .DMEM_W(DMEM_W)) u_core (
        .clk(clk), .rst_n(core_rst_n),
        .start(start), .start_pc(start_pc), .wdog(wdog),
        .arg0(arg0), .arg1(arg1), .arg2(arg2), .arg3(arg3),
        .running(running), .halted(halted), .trapped(trapped),
        .errcode(errcode), .trap_pc(trap_pc), .halt_pc(halt_pc),
        .retval(retval),
        .c_cycles(c_cycles), .c_instret(c_instret), .c_custom(c_custom),
        .c_branch(c_branch), .c_loads(c_loads), .c_stores(c_stores),
        .im_addr(core_im_addr), .im_en(core_im_en), .im_rdata(im_rdata),
        .dm_addr(core_dm_addr), .dm_en(core_dm_en), .dm_we(core_dm_we),
        .dm_be(core_dm_be), .dm_wdata(core_dm_wdata), .dm_rdata(dm_rdata),
        .dbg_valid(dbg_valid), .dbg_pc(dbg_pc), .dbg_code(dbg_code),
        .dbg_wdata(dbg_wdata), .dbg_addr(dbg_addr), .dbg_sdata(dbg_sdata)
    );

    // ---- read data mux ----------------------------------------------------
    always @* begin
        if (is_regs)      h_rdata = reg_rdata;
        else if (running) h_rdata = 32'd0;      // memories belong to the core
        else if (is_imem) h_rdata = im_rdata;
        else if (is_dmem) h_rdata = dm_rdata;
        else              h_rdata = 32'd0;
    end
endmodule
