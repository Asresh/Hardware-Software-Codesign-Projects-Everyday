// Author: Asresh
// Frame controller tying the input FIFO, line window and completion accounting together.
module sobel_stream_core #(parameter MAX_WIDTH=64)(input wire clk,input wire rst_n,input wire start_i,input wire [15:0] width_i,input wire [15:0] height_i,input wire s_valid,output wire s_ready,input wire [7:0] s_pixel,output wire m_valid,input wire m_ready,output wire [7:0] m_pixel,output wire m_last,output reg running,output reg done,output wire error,output reg [31:0] pixels_in,output reg [31:0] pixels_out);
 wire fifo_valid,window_ready;wire [8:0]fifo_data;wire [2:0]fifo_level;wire win_valid,win_last,win_error;wire [7:0]win_pixel;
 wire fifo_push_ready; assign s_ready=running&&(pixels_in<(width_i*height_i))&&fifo_push_ready;
 pixel_fifo #(.WIDTH(9),.DEPTH(4),.PTR_W(2))u_fifo(.clk(clk),.rst_n(rst_n),.s_valid(s_valid&&s_ready),.s_ready(fifo_push_ready),.s_data({1'b0,s_pixel}),.m_valid(fifo_valid),.m_ready(window_ready),.m_data(fifo_data),.level(fifo_level));
 sobel_window #(.MAX_WIDTH(MAX_WIDTH))u_window(.clk(clk),.rst_n(rst_n),.frame_reset(start_i),.width_i(width_i),.height_i(height_i),.in_valid(fifo_valid&&running),.in_ready(window_ready),.in_pixel(fifo_data[7:0]),.out_valid(win_valid),.out_ready(m_ready),.out_pixel(win_pixel),.out_last(win_last),.protocol_error(win_error));
 assign m_valid=win_valid;assign m_pixel=win_pixel;assign m_last=win_last;assign error=win_error;
 always @(posedge clk or negedge rst_n)begin if(!rst_n)begin running<=0;done<=0;pixels_in<=0;pixels_out<=0;end else begin done<=0;if(start_i)begin running<=1;pixels_in<=0;pixels_out<=0;end if(s_valid&&s_ready)pixels_in<=pixels_in+1'b1;if(m_valid&&m_ready)begin pixels_out<=pixels_out+1'b1;if(m_last)begin running<=0;done<=1;end end end end
endmodule
