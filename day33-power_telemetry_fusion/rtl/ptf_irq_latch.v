// Author: Asresh
// Completion/error latch. Pending state is sticky across firmware latency and
// is exposed as an interrupt only when enabled; set wins over simultaneous W1C.
module ptf_irq_latch (
    input  wire clk,
    input  wire rst_n,
    input  wire enable,
    input  wire set_done,
    input  wire clear_done,
    output reg  pending,
    output wire irq
);
    assign irq = enable && pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pending <= 1'b0;
        else begin
            if (clear_done)
                pending <= 1'b0;
            if (set_done)
                pending <= 1'b1;
        end
    end
endmodule
