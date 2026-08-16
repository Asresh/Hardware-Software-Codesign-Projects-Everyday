// Author: Asresh
// Combinational Sobel Gx/Gy reduction and L1 magnitude saturation.
module sobel_math(input wire [7:0] tl,tc,tr,ml,mr,bl,bc,br,output wire [7:0] magnitude);
 wire signed [11:0] gx=$signed({1'b0,tr})+($signed({1'b0,mr})*2)+$signed({1'b0,br})-$signed({1'b0,tl})-($signed({1'b0,ml})*2)-$signed({1'b0,bl});
 wire signed [11:0] gy=$signed({1'b0,tl})+($signed({1'b0,tc})*2)+$signed({1'b0,tr})-$signed({1'b0,bl})-($signed({1'b0,bc})*2)-$signed({1'b0,br});
 wire [11:0] ax=gx[11]?(~gx+1'b1):gx, ay=gy[11]?(~gy+1'b1):gy; wire [12:0] sum=ax+ay;
 assign magnitude=(sum>13'd255)?8'hff:sum[7:0];
endmodule
