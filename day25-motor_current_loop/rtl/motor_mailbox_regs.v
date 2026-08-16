// Author: Asresh
`timescale 1ns/1ps
// Selected/ready MMIO mailbox, telemetry, W1C interrupt state, and command doorbell.
module motor_mailbox_regs (
    input  wire clk,
    input  wire rst_n,
    input  wire bus_valid_i,
    input  wire bus_write_i,
    input  wire [5:0] bus_addr_i,
    input  wire [31:0] bus_wdata_i,
    output wire bus_ready_o,
    output reg  [31:0] bus_rdata_o,
    output reg  cmd_valid_o,
    input  wire cmd_ready_i,
    output reg  signed [15:0] ref_o,
    output reg  signed [15:0] meas_o,
    output reg  [7:0] gain_o,
    output reg  [15:0] trip_o,
    output reg  fault_o,
    input  wire core_busy_i,
    input  wire result_valid_i,
    output wire result_ready_o,
    input  wire [15:0] result_duty_i,
    input  wire [2:0] result_flags_i,
    output wire irq_o
);
reg irq_en_q, done_q;
reg [15:0] duty_q;
reg [2:0] flags_q;
reg [31:0] jobs_q;
assign bus_ready_o = bus_valid_i;
assign result_ready_o = !done_q;
assign irq_o = irq_en_q && done_q;

always @* begin
    case (bus_addr_i)
        6'h00: bus_rdata_o = {30'd0, irq_en_q, 1'b1};
        6'h04: bus_rdata_o = {24'd0, gain_o};
        6'h08: bus_rdata_o = {16'd0, trip_o};
        6'h0c: bus_rdata_o = {{16{ref_o[15]}}, ref_o};
        6'h10: bus_rdata_o = {{16{meas_o[15]}}, meas_o};
        6'h18: bus_rdata_o = {26'd0, flags_q, done_q, core_busy_i, cmd_ready_i};
        6'h1c: bus_rdata_o = {16'd0, duty_q};
        6'h20: bus_rdata_o = jobs_q;
        6'h24: bus_rdata_o = {31'd0, done_q};
        default: bus_rdata_o = 32'd0;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cmd_valid_o <= 1'b0;
        ref_o <= 16'sd0;
        meas_o <= 16'sd0;
        gain_o <= 8'd64;
        trip_o <= 16'd30000;
        fault_o <= 1'b0;
        irq_en_q <= 1'b0;
        done_q <= 1'b0;
        duty_q <= 16'd0;
        flags_q <= 3'd0;
        jobs_q <= 32'd0;
    end else begin
        cmd_valid_o <= 1'b0;
        if (result_valid_i && result_ready_o) begin
            duty_q <= result_duty_i;
            flags_q <= result_flags_i;
            done_q <= 1'b1;
            jobs_q <= jobs_q + 1'b1;
        end
        if (bus_valid_i && bus_write_i) begin
            case (bus_addr_i)
                6'h00: irq_en_q <= bus_wdata_i[1];
                6'h04: gain_o <= bus_wdata_i[7:0];
                6'h08: trip_o <= bus_wdata_i[15:0];
                6'h0c: ref_o <= bus_wdata_i[15:0];
                6'h10: meas_o <= bus_wdata_i[15:0];
                6'h14: if (bus_wdata_i[0] && cmd_ready_i && !done_q) begin
                    cmd_valid_o <= 1'b1;
                    fault_o <= bus_wdata_i[1];
                end
                6'h24: if (bus_wdata_i[0]) done_q <= 1'b0;
                default: begin end
            endcase
        end
    end
end
endmodule
