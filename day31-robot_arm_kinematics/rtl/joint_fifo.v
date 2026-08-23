// Author: Asresh
`timescale 1ns/1ps
module joint_fifo #(
    parameter DEPTH = 8,
    parameter ADDR_W = 3
) (
    input wire clk, input wire rst,
    input wire push, input wire [15:0] push_length, input wire signed [15:0] push_angle,
    input wire pop,
    output wire [15:0] head_length, output wire signed [15:0] head_angle,
    output wire empty, output wire full, output reg [ADDR_W:0] level
);
    reg [15:0] length_mem [0:DEPTH-1];
    reg signed [15:0] angle_mem [0:DEPTH-1];
    reg [ADDR_W-1:0] wr_ptr, rd_ptr;
    integer i;
    assign empty = (level == 0);
    assign full = (level == DEPTH);
    assign head_length = length_mem[rd_ptr];
    assign head_angle = angle_mem[rd_ptr];
    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0; rd_ptr <= 0; level <= 0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                length_mem[i] <= 0; angle_mem[i] <= 0;
            end
        end else begin
            if (push && !full) begin
                length_mem[wr_ptr] <= push_length;
                angle_mem[wr_ptr] <= push_angle;
                wr_ptr <= (wr_ptr == DEPTH-1) ? 0 : wr_ptr + 1'b1;
            end
            if (pop && !empty)
                rd_ptr <= (rd_ptr == DEPTH-1) ? 0 : rd_ptr + 1'b1;
            case ({push && !full, pop && !empty})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: level <= level;
            endcase
        end
    end
endmodule
