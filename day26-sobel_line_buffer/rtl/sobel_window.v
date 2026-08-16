// Author: Asresh
// Two-row line store plus three-column shift window; freezes on output stalls.
module sobel_window #(parameter MAX_WIDTH=64,parameter CW=7)(
 input wire clk,input wire rst_n,input wire frame_reset,input wire [15:0] width_i,input wire [15:0] height_i,
 input wire in_valid,output wire in_ready,input wire [7:0] in_pixel,
 output reg out_valid,input wire out_ready,output wire [7:0] out_pixel,output reg out_last,output reg protocol_error);
 reg [7:0] row1[0:MAX_WIDTH-1],row2[0:MAX_WIDTH-1]; reg [15:0] col,row; reg [7:0] ta,tb,ma,mb,ba,bb;
 reg [7:0] w_tl,w_tc,w_tr,w_ml,w_mr,w_bl,w_bc,w_br; wire accept=in_valid&&in_ready;
 assign in_ready=!out_valid||out_ready;
 sobel_math u_math(.tl(w_tl),.tc(w_tc),.tr(w_tr),.ml(w_ml),.mr(w_mr),.bl(w_bl),.bc(w_bc),.br(w_br),.magnitude(out_pixel));
 integer i;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin col<=0;row<=0;ta<=0;tb<=0;ma<=0;mb<=0;ba<=0;bb<=0;out_valid<=0;out_last<=0;protocol_error<=0;for(i=0;i<MAX_WIDTH;i=i+1)begin row1[i]<=0;row2[i]<=0;end end
  else if(frame_reset) begin col<=0;row<=0;ta<=0;tb<=0;ma<=0;mb<=0;ba<=0;bb<=0;out_valid<=0;out_last<=0;protocol_error<=0;end
  else begin
   if(out_valid&&out_ready)begin out_valid<=0;out_last<=0;end
   if(accept) begin
    if(col>=MAX_WIDTH||width_i<3||height_i<3)protocol_error<=1;
    row2[col[CW-1:0]]<=row1[col[CW-1:0]];row1[col[CW-1:0]]<=in_pixel;
    if(row>=2&&col>=2)begin w_tl<=ta;w_tc<=tb;w_tr<=row2[col[CW-1:0]];w_ml<=ma;w_mr<=row1[col[CW-1:0]];w_bl<=ba;w_bc<=bb;w_br<=in_pixel;out_valid<=1;out_last<=(row==height_i-1)&&(col==width_i-1);end
    if(col==width_i-1)begin col<=0;row<=row+1'b1;ta<=0;tb<=0;ma<=0;mb<=0;ba<=0;bb<=0;end
    else begin col<=col+1'b1;ta<=tb;tb<=row2[col[CW-1:0]];ma<=mb;mb<=row1[col[CW-1:0]];ba<=bb;bb<=in_pixel;end
   end
  end
 end
endmodule
