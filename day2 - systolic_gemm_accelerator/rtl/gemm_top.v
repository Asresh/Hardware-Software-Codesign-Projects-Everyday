// -----------------------------------------------------------------------------
// gemm_top.v
// Top level of the systolic GEMM tile accelerator. It computes one N x N output
// tile
//        C[i][j] = sum_{k=0..K-1} A[i][k] * B[k][j]        (K <= KMAX)
// for signed DATA_WIDTH operands, optionally accumulating onto the previous
// result so software can build a product over a K dimension larger than one
// tile by issuing several accumulating runs.
//
// Blocks:
//   wb_slave        - Wishbone B4 control plane + address decode
//   operand buffers - A^T (column-major) and B (row-major) byte SRAMs, written
//                     over the bus; sized N*KMAX bytes each
//   gemm_feeder     - sequences wavefronts and skews them into the array
//   systolic_array  - N*N output-stationary MAC grid; its accumulators *are*
//                     the C tile, so C reads come straight from them
//   completion FSM  - START->DONE handshake, cycle counter, DONE / irq
//
// Reset is active-low (rst_n) to match the rest of the repository; the Wishbone
// slave's active-high RST_I is derived from it.
// -----------------------------------------------------------------------------
`default_nettype none

module gemm_top #(
    parameter integer N          = 8,
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 32,
    parameter integer KMAX       = 64,
    parameter integer ADDR_WIDTH = 16,
    parameter integer KW         = $clog2(KMAX + 1)
) (
    input  wire                    clk,
    input  wire                    rst_n,

    // ---- Wishbone B4 classic slave ----
    input  wire [ADDR_WIDTH-1:0]   wb_adr_i,
    input  wire [31:0]             wb_dat_i,
    output wire [31:0]             wb_dat_o,
    input  wire [3:0]              wb_sel_i,
    input  wire                    wb_we_i,
    input  wire                    wb_stb_i,
    input  wire                    wb_cyc_i,
    output wire                    wb_ack_o,

    // ---- completion interrupt ----
    output wire                    irq
);
    localparam integer NBYTES = N * KMAX;             // bytes per operand buffer

    // ------------------------------------------------------------------
    // Control plane
    // ------------------------------------------------------------------
    wire [KW-1:0]          klen;
    wire                   accum_mode, irq_en, start_pulse, irq_clr_pulse;
    wire                   a_we, b_we;
    wire [6:0]             buf_waddr;
    wire [31:0]            buf_wdata;
    wire [3:0]             buf_sel;
    wire [$clog2(N*N)-1:0] c_raddr;
    wire [31:0]            c_rdata;

    reg  busy, done;
    reg  [31:0] cyc_cnt, cycles_reg;

    wb_slave #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .KMAX(KMAX), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_wb (
        .clk_i(clk), .rst_i(~rst_n),
        .wb_adr_i(wb_adr_i), .wb_dat_i(wb_dat_i), .wb_dat_o(wb_dat_o),
        .wb_sel_i(wb_sel_i), .wb_we_i(wb_we_i),
        .wb_stb_i(wb_stb_i), .wb_cyc_i(wb_cyc_i), .wb_ack_o(wb_ack_o),
        .klen(klen), .accum_mode(accum_mode), .irq_en(irq_en),
        .start_pulse(start_pulse), .irq_clr_pulse(irq_clr_pulse),
        .done(done), .busy(busy), .cycles(cycles_reg),
        .a_we(a_we), .b_we(b_we), .buf_waddr(buf_waddr),
        .buf_wdata(buf_wdata), .buf_sel(buf_sel),
        .c_raddr(c_raddr), .c_rdata(c_rdata)
    );

    // ------------------------------------------------------------------
    // Operand buffers.  A is held transposed (column-major): a_buf[k*N+i] =
    // A[i][k].  B is held row-major: b_buf[k*N+j] = B[k][j].  A window word w
    // covers bytes 4w..4w+3; the driver packs four lane bytes per word.
    // ------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] a_buf [0:NBYTES-1];
    reg [DATA_WIDTH-1:0] b_buf [0:NBYTES-1];

    integer wb;
    always @(posedge clk) begin
        if (a_we)
            for (wb = 0; wb < 4; wb = wb + 1)
                if (buf_sel[wb])
                    a_buf[{buf_waddr, 2'b00} + wb[6:0]] <= buf_wdata[wb*8 +: DATA_WIDTH];
        if (b_we)
            for (wb = 0; wb < 4; wb = wb + 1)
                if (buf_sel[wb])
                    b_buf[{buf_waddr, 2'b00} + wb[6:0]] <= buf_wdata[wb*8 +: DATA_WIDTH];
    end

    // ------------------------------------------------------------------
    // Feeder read port: present column/row rd_k of the operands.
    // ------------------------------------------------------------------
    wire [KW-1:0]           rd_k;
    wire [N*DATA_WIDTH-1:0] a_col, b_row;

    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : g_read
            assign a_col[gi*DATA_WIDTH +: DATA_WIDTH] = a_buf[rd_k*N + gi];
            assign b_row[gi*DATA_WIDTH +: DATA_WIDTH] = b_buf[rd_k*N + gi];
        end
    endgenerate

    // ------------------------------------------------------------------
    // Feeder + array
    // ------------------------------------------------------------------
    wire                    en, clr, feeder_busy, feeder_done;
    wire [N*DATA_WIDTH-1:0] a_left, b_top;
    wire [N*N*ACC_WIDTH-1:0] acc_flat;

    gemm_feeder #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .KMAX(KMAX)
    ) u_feeder (
        .clk(clk), .rst_n(rst_n),
        .start(start_pulse), .klen(klen), .accum_mode(accum_mode),
        .rd_k(rd_k), .a_col(a_col), .b_row(b_row),
        .en(en), .clr(clr), .a_left(a_left), .b_top(b_top),
        .busy(feeder_busy), .done_pulse(feeder_done)
    );

    systolic_array #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) u_array (
        .clk(clk), .rst_n(rst_n), .en(en), .clr(clr),
        .a_left(a_left), .b_top(b_top), .acc_flat(acc_flat)
    );

    assign c_rdata = acc_flat[c_raddr*ACC_WIDTH +: ACC_WIDTH];

    // ------------------------------------------------------------------
    // Completion FSM: measure START->DONE cycles, raise DONE / irq.
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0; done <= 1'b0; cyc_cnt <= 32'd0; cycles_reg <= 32'd0;
        end else begin
            if (start_pulse) begin
                busy <= 1'b1; done <= 1'b0; cyc_cnt <= 32'd0;
            end else if (feeder_done) begin
                busy <= 1'b0; done <= 1'b1; cycles_reg <= cyc_cnt + 32'd1;
            end else if (irq_clr_pulse) begin
                done <= 1'b0;
            end
            if (busy) cyc_cnt <= cyc_cnt + 32'd1;
        end
    end

    assign irq = done & irq_en;
endmodule

`default_nettype wire
