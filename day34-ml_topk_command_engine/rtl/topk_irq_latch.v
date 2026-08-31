// Author: Asresh
`timescale 1ns/1ps
module topk_irq_latch(input wire clk,input wire rst_n,input wire enable,
    input wire set_pending,input wire clear_pending,output reg pending,output wire irq);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) pending<=0;
        else if(clear_pending) pending<=0; else if(set_pending) pending<=1;
    end
    assign irq=enable && pending;
endmodule
