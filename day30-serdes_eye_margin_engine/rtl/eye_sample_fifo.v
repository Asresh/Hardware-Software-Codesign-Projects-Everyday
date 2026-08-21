// Author: Asresh
module eye_sample_fifo #(
    parameter WIDTH = 24,
    parameter DEPTH = 8,
    parameter PTR_W = 3
) (
    input wire clk, input wire rst_n, input wire clear,
    input wire in_valid, output wire in_ready, input wire [WIDTH-1:0] in_data,
    output wire out_valid, input wire out_ready, output wire [WIDTH-1:0] out_data,
    output wire [PTR_W:0] level
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [PTR_W-1:0] wr_ptr, rd_ptr;
    reg [PTR_W:0] count;
    wire push = in_valid && in_ready;
    wire pop = out_valid && out_ready;
    assign in_ready = (count < DEPTH);
    assign out_valid = (count != 0);
    assign out_data = mem[rd_ptr];
    assign level = count;
    always @(posedge clk) begin
        if (!rst_n || clear) begin wr_ptr <= 0; rd_ptr <= 0; count <= 0; end
        else begin
            if (push) begin mem[wr_ptr] <= in_data; wr_ptr <= wr_ptr + 1'b1; end
            if (pop) rd_ptr <= rd_ptr + 1'b1;
            case ({push,pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule
