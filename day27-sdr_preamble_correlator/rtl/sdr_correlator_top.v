// Author: Asresh
// Top level joining the control plane, eight-lane datapath and completion IRQ.
module sdr_correlator_top #(
    parameter LANES = 8,
    parameter W = 8
) (
    input clk, input rst_n,
    input bus_valid, input bus_write,
    input [7:0] bus_addr, input [31:0] bus_wdata,
    output bus_ready, output [31:0] bus_rdata,
    input [(LANES*2*W)-1:0] s_axis_tdata,
    input [15:0] s_axis_tuser,
    input s_axis_tlast, input s_axis_tvalid,
    output s_axis_tready,
    output [63:0] m_axis_tdata,
    output m_axis_tlast, output m_axis_tvalid,
    input m_axis_tready,
    output irq
);
    wire enabled;
    wire [40:0] threshold;
    wire [(LANES*W)-1:0] tap_i_flat, tap_q_flat;
    wire result_fire = m_axis_tvalid && m_axis_tready;
    wire result_detected = m_axis_tdata[57];
    wire frame_last_fire = result_fire && m_axis_tlast;

    correlator_csr #(.LANES(LANES), .W(W)) csr (
        .clk(clk), .rst_n(rst_n), .bus_valid(bus_valid),
        .bus_write(bus_write), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_ready(bus_ready), .bus_rdata(bus_rdata), .enabled(enabled),
        .threshold(threshold), .tap_i_flat(tap_i_flat), .tap_q_flat(tap_q_flat),
        .result_fire(result_fire), .result_detected(result_detected),
        .frame_last_fire(frame_last_fire), .irq(irq)
    );
    preamble_correlator_core #(.LANES(LANES), .W(W)) core (
        .clk(clk), .rst_n(rst_n), .enabled(enabled), .threshold(threshold),
        .tap_i_flat(tap_i_flat), .tap_q_flat(tap_q_flat),
        .s_data(s_axis_tdata), .s_tag(s_axis_tuser), .s_last(s_axis_tlast),
        .s_valid(s_axis_tvalid), .s_ready(s_axis_tready),
        .m_data(m_axis_tdata), .m_last(m_axis_tlast), .m_valid(m_axis_tvalid),
        .m_ready(m_axis_tready)
    );
endmodule
