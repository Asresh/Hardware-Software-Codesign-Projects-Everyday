// Author: Asresh
`timescale 1ns/1ps
module robot_arm_kinematics_top #(
    parameter MAX_JOINTS=8,
    parameter COUNT_W=4,
    parameter FIFO_ADDR_W=3
) (
    input wire clk, input wire rst_n,
    input wire spi_sclk, input wire spi_cs_n, input wire spi_mosi, output wire spi_miso,
    output wire irq
);
    wire rst = !rst_n;
    wire rx_valid, tx_load, soft_reset, fifo_push, fifo_pop, fifo_full, fifo_empty;
    wire [39:0] rx_word, tx_word;
    wire [15:0] push_length, fifo_length;
    wire signed [15:0] push_angle, fifo_angle;
    wire [FIFO_ADDR_W:0] fifo_level;
    wire engine_start, engine_busy, engine_done, engine_error;
    wire [COUNT_W-1:0] joint_count, joints_done;
    wire signed [31:0] result_x, result_y;
    wire [31:0] engine_cycles;
    wire internal_rst = rst | soft_reset;
    spi_packet_slave u_spi(.clk(clk),.rst(rst),.spi_sclk(spi_sclk),.spi_cs_n(spi_cs_n),.spi_mosi(spi_mosi),
        .spi_miso(spi_miso),.rx_valid(rx_valid),.rx_word(rx_word),.tx_load(tx_load),.tx_word(tx_word));
    kinematics_command #(.MAX_JOINTS(MAX_JOINTS),.COUNT_W(COUNT_W)) u_command(
        .clk(clk),.rst(rst),.rx_valid(rx_valid),.rx_word(rx_word),.tx_load(tx_load),.tx_word(tx_word),
        .soft_reset(soft_reset),.fifo_push(fifo_push),.push_length(push_length),.push_angle(push_angle),
        .fifo_full(fifo_full),.fifo_level(fifo_level),.engine_start(engine_start),.joint_count(joint_count),
        .engine_busy(engine_busy),.engine_done(engine_done),.engine_error(engine_error),.result_x(result_x),.result_y(result_y),
        .engine_cycles(engine_cycles),.joints_done(joints_done),.irq(irq));
    joint_fifo #(.DEPTH(MAX_JOINTS),.ADDR_W(FIFO_ADDR_W)) u_fifo(.clk(clk),.rst(internal_rst),
        .push(fifo_push),.push_length(push_length),.push_angle(push_angle),.pop(fifo_pop),
        .head_length(fifo_length),.head_angle(fifo_angle),.empty(fifo_empty),.full(fifo_full),.level(fifo_level));
    kinematics_engine #(.MAX_JOINTS(MAX_JOINTS),.COUNT_W(COUNT_W)) u_engine(.clk(clk),.rst(internal_rst),
        .start(engine_start),.requested_joints(joint_count),.fifo_level(fifo_level),.fifo_pop(fifo_pop),
        .fifo_length(fifo_length),.fifo_angle(fifo_angle),.busy(engine_busy),.done(engine_done),.error(engine_error),
        .result_x_q8(result_x),.result_y_q8(result_y),.cycle_count(engine_cycles),.joints_done(joints_done));
endmodule
