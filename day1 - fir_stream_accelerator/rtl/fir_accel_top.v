// -----------------------------------------------------------------------------
// fir_accel_top.v
// Top level of the streaming FIR accelerator. Ties together:
//   * axi_lite_regfile  - AXI4-Lite control plane (coefficients, length, start)
//   * sync_fifo (in)    - AXI4-Stream input buffer, absorbs producer bursts
//   * fir_datapath      - transposed-form FIR MAC chain
//   * sync_fifo (out)   - AXI4-Stream output buffer, absorbs consumer stalls
//   * completion FSM    - counts results, raises DONE / irq at job end
//
// Data plane : AXI4-Stream (s_axis in, m_axis out) with full valid/ready
//              backpressure. A stall on m_axis_tready propagates through the
//              output FIFO -> datapath -> input FIFO -> s_axis_tready.
// Control    : AXI4-Lite. Software loads coefficients + LENGTH, pulses START,
//              then streams LENGTH samples and drains LENGTH results; DONE and
//              the irq line signal completion.
// -----------------------------------------------------------------------------
`default_nettype none

module fir_accel_top #(
    parameter integer DATA_WIDTH = 16,
    parameter integer COEF_WIDTH = 16,
    parameter integer TAPS       = 8,
    parameter integer FIFO_DEPTH = 16,
    parameter integer LEN_WIDTH  = 16,
    parameter integer ADDR_WIDTH = 8,
    parameter integer ACC_WIDTH  = DATA_WIDTH + COEF_WIDTH + $clog2(TAPS)
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // ---- AXI4-Lite control ----
    input  wire [ADDR_WIDTH-1:0]       s_axil_awaddr,
    input  wire                        s_axil_awvalid,
    output wire                        s_axil_awready,
    input  wire [31:0]                 s_axil_wdata,
    input  wire [3:0]                  s_axil_wstrb,
    input  wire                        s_axil_wvalid,
    output wire                        s_axil_wready,
    output wire [1:0]                  s_axil_bresp,
    output wire                        s_axil_bvalid,
    input  wire                        s_axil_bready,
    input  wire [ADDR_WIDTH-1:0]       s_axil_araddr,
    input  wire                        s_axil_arvalid,
    output wire                        s_axil_arready,
    output wire [31:0]                 s_axil_rdata,
    output wire [1:0]                  s_axil_rresp,
    output wire                        s_axil_rvalid,
    input  wire                        s_axil_rready,

    // ---- AXI4-Stream input (samples) ----
    input  wire [DATA_WIDTH-1:0]       s_axis_tdata,
    input  wire                        s_axis_tvalid,
    output wire                        s_axis_tready,
    input  wire                        s_axis_tlast,     // accepted, not required

    // ---- AXI4-Stream output (results) ----
    output wire [ACC_WIDTH-1:0]        m_axis_tdata,
    output wire                        m_axis_tvalid,
    input  wire                        m_axis_tready,
    output wire                        m_axis_tlast,

    // ---- interrupt / completion ----
    output wire                        irq
);
    // ------------------------------------------------------------------
    // Control plane
    // ------------------------------------------------------------------
    wire [TAPS*COEF_WIDTH-1:0] coef_flat;
    wire [LEN_WIDTH-1:0]       length;
    wire                       start_pulse, clr_pulse, irq_en;
    reg                        busy, done;
    reg  [31:0]                samples_out;
    wire [31:0]                in_level, out_level;

    axi_lite_regfile #(
        .TAPS(TAPS), .COEF_WIDTH(COEF_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .LEN_WIDTH(LEN_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(s_axil_awaddr), .s_awvalid(s_axil_awvalid), .s_awready(s_axil_awready),
        .s_wdata(s_axil_wdata), .s_wstrb(s_axil_wstrb), .s_wvalid(s_axil_wvalid), .s_wready(s_axil_wready),
        .s_bresp(s_axil_bresp), .s_bvalid(s_axil_bvalid), .s_bready(s_axil_bready),
        .s_araddr(s_axil_araddr), .s_arvalid(s_axil_arvalid), .s_arready(s_axil_arready),
        .s_rdata(s_axil_rdata), .s_rresp(s_axil_rresp), .s_rvalid(s_axil_rvalid), .s_rready(s_axil_rready),
        .coef_flat(coef_flat), .length(length),
        .start_pulse(start_pulse), .clr_pulse(clr_pulse), .irq_en(irq_en),
        .done(done), .busy(busy), .samples_out(samples_out),
        .in_level(in_level), .out_level(out_level)
    );

    wire job_flush = start_pulse | clr_pulse;

    // ------------------------------------------------------------------
    // Input stream FIFO  (s_axis -> datapath)
    // ------------------------------------------------------------------
    // Admission is gated by BUSY *and* an admitted-sample count against LENGTH,
    // so a free-running producer can never push more than LENGTH samples into a
    // job (TREADY deasserts once LENGTH have been accepted).
    reg  [LEN_WIDTH-1:0]  in_admitted;
    wire                  admit_open = busy & (in_admitted < length);
    wire                  in_fifo_wr_valid = s_axis_tvalid & admit_open;
    wire                  in_fifo_wr_ready;
    wire                  dp_s_valid, dp_s_ready;
    wire [DATA_WIDTH-1:0] dp_s_data;

    assign s_axis_tready = admit_open & in_fifo_wr_ready;

    always @(posedge clk) begin
        if (!rst_n)                             in_admitted <= {LEN_WIDTH{1'b0}};
        else if (start_pulse | clr_pulse)       in_admitted <= {LEN_WIDTH{1'b0}};
        else if (s_axis_tvalid & s_axis_tready) in_admitted <= in_admitted + 1'b1;
    end

    sync_fifo #(.WIDTH(DATA_WIDTH), .DEPTH(FIFO_DEPTH)) u_in_fifo (
        .clk(clk), .rst_n(rst_n), .flush(job_flush),
        .wr_valid(in_fifo_wr_valid), .wr_ready(in_fifo_wr_ready), .wr_data(s_axis_tdata),
        .rd_valid(dp_s_valid), .rd_ready(dp_s_ready), .rd_data(dp_s_data),
        .level(in_level)
    );

    // ------------------------------------------------------------------
    // FIR datapath
    // ------------------------------------------------------------------
    wire                 dp_m_valid, dp_m_ready;
    wire [ACC_WIDTH-1:0] dp_m_data;

    fir_datapath #(
        .DATA_WIDTH(DATA_WIDTH), .COEF_WIDTH(COEF_WIDTH), .TAPS(TAPS), .ACC_WIDTH(ACC_WIDTH)
    ) u_dp (
        .clk(clk), .rst_n(rst_n), .clr(job_flush),
        .coef_flat(coef_flat),
        .s_valid(dp_s_valid), .s_ready(dp_s_ready), .s_data(dp_s_data),
        .m_valid(dp_m_valid), .m_ready(dp_m_ready), .m_data(dp_m_data)
    );

    // ------------------------------------------------------------------
    // Completion FSM
    // ------------------------------------------------------------------
    wire        prod_fire  = dp_m_valid & dp_m_ready;                  // result committed to out FIFO
    wire        last_result = busy & (samples_out + 32'd1 == {{(32-LEN_WIDTH){1'b0}}, length});

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0; done <= 1'b0; samples_out <= 32'd0;
        end else if (start_pulse) begin
            samples_out <= 32'd0;
            if (length == {LEN_WIDTH{1'b0}}) begin busy <= 1'b0; done <= 1'b1; end
            else                                 begin busy <= 1'b1; done <= 1'b0; end
        end else if (clr_pulse) begin
            busy <= 1'b0; done <= 1'b0; samples_out <= 32'd0;
        end else if (busy & prod_fire) begin
            samples_out <= samples_out + 32'd1;
            if (last_result) begin busy <= 1'b0; done <= 1'b1; end
        end
    end

    assign irq = done & irq_en;

    // ------------------------------------------------------------------
    // Output stream FIFO  (datapath -> m_axis), carries a per-sample TLAST bit
    // ------------------------------------------------------------------
    wire                 out_fifo_wr_ready;
    wire [ACC_WIDTH:0]   out_fifo_rd_data;
    wire                 out_fifo_rd_valid;

    assign dp_m_ready = out_fifo_wr_ready;                            // datapath stalls if out FIFO full

    sync_fifo #(.WIDTH(ACC_WIDTH+1), .DEPTH(FIFO_DEPTH)) u_out_fifo (
        .clk(clk), .rst_n(rst_n), .flush(job_flush),
        .wr_valid(dp_m_valid), .wr_ready(out_fifo_wr_ready),
        .wr_data({last_result, dp_m_data}),
        .rd_valid(out_fifo_rd_valid), .rd_ready(m_axis_tready), .rd_data(out_fifo_rd_data),
        .level(out_level)
    );

    assign m_axis_tvalid = out_fifo_rd_valid;
    assign m_axis_tdata  = out_fifo_rd_data[ACC_WIDTH-1:0];
    assign m_axis_tlast  = out_fifo_rd_data[ACC_WIDTH];

endmodule

`default_nettype wire
