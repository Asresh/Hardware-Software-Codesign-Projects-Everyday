// Author: Asresh
`timescale 1ns/1ps
module kinematics_engine #(
    parameter MAX_JOINTS = 8,
    parameter COUNT_W = 4
) (
    input wire clk, input wire rst, input wire start,
    input wire [COUNT_W-1:0] requested_joints,
    input wire [COUNT_W-1:0] fifo_level,
    output reg fifo_pop, input wire [15:0] fifo_length, input wire signed [15:0] fifo_angle,
    output reg busy, output reg done, output reg error,
    output reg signed [31:0] result_x_q8, output reg signed [31:0] result_y_q8,
    output reg [31:0] cycle_count, output reg [COUNT_W-1:0] joints_done
);
    localparam IDLE=2'd0, ISSUE=2'd1, WAIT_CORDIC=2'd2;
    localparam signed [18:0] PI = 19'sd25736;
    localparam signed [18:0] TWO_PI = 19'sd51472;
    reg [1:0] state;
    reg signed [17:0] heading;
    reg signed [17:0] cordic_angle;
    reg [15:0] active_length;
    reg cordic_start;
    wire cordic_busy, cordic_done;
    wire signed [17:0] cordic_cos, cordic_sin;
    wire signed [18:0] raw_heading = $signed(heading) + $signed(fifo_angle);
    wire signed [17:0] wrapped_heading = (raw_heading > PI) ? raw_heading - TWO_PI :
                                          (raw_heading < -PI) ? raw_heading + TWO_PI : raw_heading;
    wire signed [49:0] x_product = $signed({1'b0,active_length}) * $signed(cordic_cos);
    wire signed [49:0] y_product = $signed({1'b0,active_length}) * $signed(cordic_sin);
    wire signed [31:0] x_step = x_product >>> 15;
    wire signed [31:0] y_step = y_product >>> 15;
    cordic_rotator u_cordic(.clk(clk),.rst(rst),.start(cordic_start),.angle_q13(cordic_angle),
        .busy(cordic_busy),.done(cordic_done),.cos_q15(cordic_cos),.sin_q15(cordic_sin));
    always @(posedge clk) begin
        if (rst) begin
            state<=IDLE; heading<=0; cordic_angle<=0; active_length<=0; cordic_start<=0; fifo_pop<=0; busy<=0; done<=0; error<=0;
            result_x_q8<=0; result_y_q8<=0; cycle_count<=0; joints_done<=0;
        end else begin
            cordic_start<=0; fifo_pop<=0; done<=0;
            if (busy) cycle_count <= cycle_count + 1'b1;
            case (state)
                IDLE: if (start) begin
                    error<=0; result_x_q8<=0; result_y_q8<=0; cycle_count<=0; joints_done<=0; heading<=0;
                    if (requested_joints==0 || requested_joints>MAX_JOINTS || fifo_level<requested_joints) begin error<=1; done<=1; end
                    else begin busy<=1; state<=ISSUE; end
                end
                ISSUE: begin
                    heading<=wrapped_heading; cordic_angle<=wrapped_heading; active_length<=fifo_length; fifo_pop<=1; cordic_start<=1; state<=WAIT_CORDIC;
                end
                WAIT_CORDIC: if (cordic_done) begin
                    result_x_q8<=result_x_q8+x_step; result_y_q8<=result_y_q8+y_step; joints_done<=joints_done+1'b1;
                    if (joints_done+1'b1==requested_joints) begin busy<=0; done<=1; state<=IDLE; end
                    else state<=ISSUE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
