// Author: Asresh
// Merges two already-sorted top-two lists. A four-candidate insertion network
// is used at each internal node of the balanced reduction tree.
`timescale 1ns/1ps
module topk_merge (
    input wire signed [15:0] a0v, input wire [2:0] a0i,
    input wire signed [15:0] a1v, input wire [2:0] a1i,
    input wire signed [15:0] b0v, input wire [2:0] b0i,
    input wire signed [15:0] b1v, input wire [2:0] b1i,
    output reg signed [15:0] o0v, output reg [2:0] o0i,
    output reg signed [15:0] o1v, output reg [2:0] o1i
);
    reg signed [15:0] cv [0:3];
    reg [2:0] ci [0:3];
    reg signed [15:0] tval;
    reg [2:0] tidx;
    integer x, y;
    always @* begin
        cv[0]=a0v; ci[0]=a0i; cv[1]=a1v; ci[1]=a1i;
        cv[2]=b0v; ci[2]=b0i; cv[3]=b1v; ci[3]=b1i;
        for (x=0; x<3; x=x+1)
            for (y=x+1; y<4; y=y+1)
                if ((cv[y] > cv[x]) || ((cv[y] == cv[x]) && (ci[y] < ci[x]))) begin
                    tval=cv[x]; cv[x]=cv[y]; cv[y]=tval;
                    tidx=ci[x]; ci[x]=ci[y]; ci[y]=tidx;
                end
        o0v=cv[0]; o0i=ci[0]; o1v=cv[1]; o1i=ci[1];
    end
endmodule
