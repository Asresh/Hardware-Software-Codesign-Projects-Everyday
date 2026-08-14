// Author: Asresh
// Correction FIFO decouples read/syndrome throughput from DDR writeback.
module scrub_fifo #(parameter DEPTH=4, parameter AW=32)(
    input wire clk, input wire rst_n, input wire in_valid, output wire in_ready,
    input wire [AW-1:0] in_addr, input wire [38:0] in_code,
    output wire out_valid, input wire out_ready, output wire [AW-1:0] out_addr,
    output wire [38:0] out_code, output wire empty, output wire full);
    localparam PW = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    reg [AW-1:0] addr_mem [0:DEPTH-1]; reg [38:0] code_mem [0:DEPTH-1];
    reg [PW-1:0] rp, wp; reg [PW:0] count;
    wire push = in_valid && in_ready; wire pop = out_valid && out_ready;
    assign empty=(count==0); assign full=(count==DEPTH); assign in_ready=!full||pop;
    assign out_valid=!empty; assign out_addr=addr_mem[rp]; assign out_code=code_mem[rp];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rp<=0; wp<=0; count<=0; end else begin
            if (push) begin addr_mem[wp]<=in_addr; code_mem[wp]<=in_code; wp<=(wp==DEPTH-1)?0:wp+1'b1; end
            if (pop) rp<=(rp==DEPTH-1)?0:rp+1'b1;
            case ({push,pop}) 2'b10:count<=count+1'b1; 2'b01:count<=count-1'b1; default:count<=count; endcase
        end
    end
endmodule
