// Author: Asresh
`timescale 1ns/1ps
// Parameterized mailbox decoupling FIFO. Default depth is four commands.
module command_fifo #(
    parameter DEPTH = 4,
    parameter PTR_W = (DEPTH < 2) ? 1 : $clog2(DEPTH)
) (
    input  wire clk,
    input  wire rst_n,
    input  wire push_i,
    output wire ready_o,
    input  wire signed [15:0] ref_i,
    input  wire signed [15:0] meas_i,
    input  wire [7:0] gain_i,
    input  wire [15:0] trip_i,
    input  wire fault_i,
    input  wire pop_i,
    output wire valid_o,
    output wire signed [15:0] ref_o,
    output wire signed [15:0] meas_o,
    output wire [7:0] gain_o,
    output wire [15:0] trip_o,
    output wire fault_o
);
reg signed [15:0] ref_mem [0:DEPTH-1];
reg signed [15:0] meas_mem [0:DEPTH-1];
reg [7:0] gain_mem [0:DEPTH-1];
reg [15:0] trip_mem [0:DEPTH-1];
reg fault_mem [0:DEPTH-1];
reg [PTR_W-1:0] wr_q, rd_q;
reg [PTR_W:0] count_q;
wire push_w = push_i && ready_o;
wire pop_w = pop_i && valid_o;
assign ready_o = (count_q < DEPTH);
assign valid_o = (count_q != 0);
assign ref_o = ref_mem[rd_q];
assign meas_o = meas_mem[rd_q];
assign gain_o = gain_mem[rd_q];
assign trip_o = trip_mem[rd_q];
assign fault_o = fault_mem[rd_q];
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_q <= {PTR_W{1'b0}};
        rd_q <= {PTR_W{1'b0}};
        count_q <= {(PTR_W+1){1'b0}};
    end else begin
        if (push_w) begin
            ref_mem[wr_q] <= ref_i;
            meas_mem[wr_q] <= meas_i;
            gain_mem[wr_q] <= gain_i;
            trip_mem[wr_q] <= trip_i;
            fault_mem[wr_q] <= fault_i;
            wr_q <= (wr_q == DEPTH-1) ? {PTR_W{1'b0}} : wr_q + 1'b1;
        end
        if (pop_w)
            rd_q <= (rd_q == DEPTH-1) ? {PTR_W{1'b0}} : rd_q + 1'b1;
        case ({push_w, pop_w})
            2'b10: count_q <= count_q + 1'b1;
            2'b01: count_q <= count_q - 1'b1;
            default: count_q <= count_q;
        endcase
    end
end
endmodule
