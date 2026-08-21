// Author: Asresh
module eye_apb_csr #(
    parameter COUNT_W = 9
) (
    input wire clk, input wire rst_n,
    input wire psel, input wire penable, input wire pwrite,
    input wire [7:0] paddr, input wire [31:0] pwdata,
    output reg [31:0] prdata, output wire pready, output reg pslverr,
    output reg start_pulse, output reg irq_enable, output reg [15:0] error_limit,
    input wire engine_done, input wire [6:0] best_start,
    input wire [COUNT_W-1:0] best_length, input wire [COUNT_W-1:0] sample_count,
    input wire [3:0] fifo_level, output wire irq
);
    reg busy, irq_done;
    wire access = psel && penable;
    assign pready = 1'b1;
    assign irq = irq_enable && irq_done;
    always @(posedge clk) begin
        if (!rst_n) begin
            start_pulse <= 0; irq_enable <= 0; error_limit <= 0;
            busy <= 0; irq_done <= 0;
        end else begin
            start_pulse <= 0;
            if (engine_done) begin busy <= 0; irq_done <= 1; end
            if (access && pwrite && paddr == 8'h00) begin
                irq_enable <= pwdata[1];
                if (pwdata[0]) begin start_pulse <= 1; busy <= 1; irq_done <= 0; end
            end
            if (access && pwrite && paddr == 8'h08) error_limit <= pwdata[15:0];
            if (access && pwrite && paddr == 8'h1c && pwdata[0]) irq_done <= 0;
        end
    end
    always @* begin
        prdata = 0; pslverr = 0;
        case (paddr)
            8'h00: prdata = {30'b0,irq_enable,1'b0};
            8'h04: prdata = {29'b0,irq_done,busy,engine_done};
            8'h08: prdata = {16'b0,error_limit};
            8'h0c: prdata = {25'b0,best_start};
            8'h10: prdata = best_length;
            8'h14: prdata = sample_count;
            8'h18: prdata = {28'b0,fifo_level};
            8'h1c: prdata = {31'b0,irq_done};
            8'h20: prdata = 32'h45594530;
            default: pslverr = access;
        endcase
    end
endmodule
