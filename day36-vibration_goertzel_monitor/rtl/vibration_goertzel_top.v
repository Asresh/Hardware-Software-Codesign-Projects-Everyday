// Author: Asresh
`timescale 1ns/1ps
module vibration_goertzel_top #(
    parameter SAMPLE_W = 12,
    parameter ACC_W = 40,
    parameter COEF_W = 12,
    parameter BINS = 4
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     wb_cyc_i,
    input  wire                     wb_stb_i,
    input  wire                     wb_we_i,
    input  wire [4:0]               wb_adr_i,
    input  wire [31:0]              wb_dat_i,
    output reg  [31:0]              wb_dat_o,
    output wire                     wb_ack_o,
    input  wire [SAMPLE_W-1:0]      s_axis_tdata,
    input  wire                     s_axis_tlast,
    input  wire                     s_axis_tvalid,
    output wire                     s_axis_tready,
    output wire                     irq_o
);
    reg enable;
    reg irq;
    reg [31:0] sample_count;
    reg [31:0] frame_count;
    reg signed [COEF_W-1:0] coeff [0:BINS-1];
    reg [63:0] result_power;
    reg [7:0] result_bin;
    wire [SAMPLE_W-1:0] sample_data;
    wire sample_last;
    wire sample_valid;
    wire sample_ready = enable && !irq;
    wire sample_accept = sample_valid && sample_ready;
    wire clear = wb_cyc_i && wb_stb_i && wb_we_i && (wb_adr_i == 5'd0) && wb_dat_i[1];
    wire [BINS-1:0] bin_valid;
    wire [(BINS*64)-1:0] powers;
    wire [63:0] peak_power;
    wire [7:0] peak_bin;
    integer i;

    assign wb_ack_o = wb_cyc_i && wb_stb_i;
    assign irq_o = irq;

    axis_skid_buffer #(.WIDTH(SAMPLE_W)) ingress (
        .clk(clk), .rst(rst || clear),
        .s_data(s_axis_tdata), .s_last(s_axis_tlast), .s_valid(s_axis_tvalid), .s_ready(s_axis_tready),
        .m_data(sample_data), .m_last(sample_last), .m_valid(sample_valid), .m_ready(sample_ready)
    );

    genvar g;
    generate
        for (g = 0; g < BINS; g = g + 1) begin : GEN_BINS
            goertzel_bin #(.SAMPLE_W(SAMPLE_W), .ACC_W(ACC_W), .COEF_W(COEF_W)) bin (
                .clk(clk), .rst(rst), .clear(clear), .accept(sample_accept), .frame_end(sample_last),
                .sample(sample_data), .coefficient(coeff[g]),
                .power(powers[(g*64) +: 64]), .power_valid(bin_valid[g])
            );
        end
    endgenerate

    power_peak_selector #(.BINS(BINS)) selector (
        .powers(powers), .peak_power(peak_power), .peak_bin(peak_bin)
    );

    always @* begin
        case (wb_adr_i)
            5'd0: wb_dat_o = {30'd0, 1'b0, enable};
            5'd1: wb_dat_o = {30'd0, irq, enable};
            5'd2: wb_dat_o = sample_count;
            5'd3: wb_dat_o = frame_count;
            5'd4: wb_dat_o = {24'd0, result_bin};
            5'd5: wb_dat_o = result_power[31:0];
            5'd6: wb_dat_o = result_power[63:32];
            5'd7: wb_dat_o = {{(32-COEF_W){coeff[0][COEF_W-1]}}, coeff[0]};
            5'd8: wb_dat_o = {{(32-COEF_W){coeff[1][COEF_W-1]}}, coeff[1]};
            5'd9: wb_dat_o = {{(32-COEF_W){coeff[2][COEF_W-1]}}, coeff[2]};
            5'd10: wb_dat_o = {{(32-COEF_W){coeff[3][COEF_W-1]}}, coeff[3]};
            default: wb_dat_o = 32'd0;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            enable <= 1'b0;
            irq <= 1'b0;
            sample_count <= 32'd0;
            frame_count <= 32'd0;
            result_power <= 64'd0;
            result_bin <= 8'd0;
            coeff[0] <= 12'sd362;
            coeff[1] <= 12'sd256;
            coeff[2] <= 12'sd0;
            coeff[3] <= -12'sd256;
        end else begin
            if (clear) begin
                sample_count <= 32'd0;
                frame_count <= 32'd0;
                result_power <= 64'd0;
                result_bin <= 8'd0;
                irq <= 1'b0;
            end
            if (wb_cyc_i && wb_stb_i && wb_we_i) begin
                case (wb_adr_i)
                    5'd0: enable <= wb_dat_i[0];
                    5'd1: if (wb_dat_i[0]) irq <= 1'b0;
                    5'd7: coeff[0] <= wb_dat_i[COEF_W-1:0];
                    5'd8: coeff[1] <= wb_dat_i[COEF_W-1:0];
                    5'd9: coeff[2] <= wb_dat_i[COEF_W-1:0];
                    5'd10: coeff[3] <= wb_dat_i[COEF_W-1:0];
                endcase
            end
            if (sample_accept) sample_count <= sample_count + 1'b1;
            if (bin_valid[0]) begin
                result_power <= peak_power;
                result_bin <= peak_bin;
                frame_count <= frame_count + 1'b1;
                irq <= 1'b1;
            end
        end
    end
endmodule
