// Author: Asresh
`timescale 1ns/1ps
module kinematics_command #(
    parameter MAX_JOINTS=8,
    parameter COUNT_W=4
) (
    input wire clk, input wire rst,
    input wire rx_valid, input wire [39:0] rx_word,
    output reg tx_load, output reg [39:0] tx_word,
    output reg soft_reset, output reg fifo_push,
    output reg [15:0] push_length, output reg signed [15:0] push_angle,
    input wire fifo_full, input wire [COUNT_W-1:0] fifo_level,
    output reg engine_start, output reg [COUNT_W-1:0] joint_count,
    input wire engine_busy, input wire engine_done, input wire engine_error,
    input wire signed [31:0] result_x, input wire signed [31:0] result_y,
    input wire [31:0] engine_cycles, input wire [COUNT_W-1:0] joints_done,
    output reg irq
);
    localparam OP_NOP=8'h00, OP_RESET=8'h01, OP_CONFIG=8'h10, OP_PUSH=8'h20, OP_START=8'h30;
    localparam OP_STATUS=8'h40, OP_X=8'h41, OP_Y=8'h42, OP_CYCLES=8'h43, OP_JOINTS=8'h44, OP_ACK=8'h50;
    reg irq_enable, protocol_error, done_latched;
    reg [31:0] response;
    wire [7:0] opcode = rx_word[39:32];
    wire [31:0] payload = rx_word[31:0];
    always @* begin
        case (opcode)
            OP_STATUS: response={24'd0,protocol_error,engine_error,irq,done_latched,engine_busy,2'b0,fifo_full};
            OP_X: response=result_x;
            OP_Y: response=result_y;
            OP_CYCLES: response=engine_cycles;
            OP_JOINTS: response={{(32-COUNT_W){1'b0}},joints_done};
            default: response=32'h4b494e31;
        endcase
    end
    always @(posedge clk) begin
        if (rst) begin
            tx_load<=0; tx_word<=0; soft_reset<=0; fifo_push<=0; push_length<=0; push_angle<=0;
            engine_start<=0; joint_count<=0; irq_enable<=0; protocol_error<=0; done_latched<=0; irq<=0;
        end else begin
            tx_load<=0; soft_reset<=0; fifo_push<=0; engine_start<=0;
            if (engine_done) begin done_latched<=1; if (irq_enable) irq<=1; end
            if (rx_valid) begin
                tx_load<=1; tx_word<={opcode,response};
                case (opcode)
                    OP_NOP: begin end
                    OP_RESET: begin soft_reset<=1; irq<=0; done_latched<=0; protocol_error<=0; joint_count<=0; end
                    OP_CONFIG: begin
                        if (engine_busy || payload[7:0]==0 || payload[7:0]>MAX_JOINTS) protocol_error<=1;
                        else begin joint_count<=payload[COUNT_W-1:0]; irq_enable<=payload[8]; protocol_error<=0; end
                    end
                    OP_PUSH: begin
                        if (engine_busy || fifo_full) protocol_error<=1;
                        else begin fifo_push<=1; push_length<=payload[31:16]; push_angle<=payload[15:0]; end
                    end
                    OP_START: begin if (engine_busy) protocol_error<=1; else begin engine_start<=1; done_latched<=0; end end
                    OP_STATUS,OP_X,OP_Y,OP_CYCLES,OP_JOINTS: begin end
                    OP_ACK: irq<=0;
                    default: protocol_error<=1;
                endcase
            end
        end
    end
endmodule
