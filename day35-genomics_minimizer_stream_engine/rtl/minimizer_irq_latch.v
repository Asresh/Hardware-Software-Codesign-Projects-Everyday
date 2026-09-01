// Author: Asresh
module minimizer_irq_latch(input wire clk, input wire rst_n, input wire set, input wire clear, output reg irq);
    always @(posedge clk) begin
        if (!rst_n) irq <= 1'b0;
        else if (clear) irq <= 1'b0;
        else if (set) irq <= 1'b1;
    end
endmodule
