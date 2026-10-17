// Author: Asresh
`timescale 1ns/1ps
module pcie_order_fifo #(
  parameter DEPTH = 8,
  parameter TAG_W = 3,
  parameter PTR_W = 3
)(
  input wire clk,
  input wire reset_n,
  input wire clear,
  input wire push,
  input wire [TAG_W-1:0] push_tag,
  input wire pop,
  output wire [TAG_W-1:0] head_tag,
  output wire empty,
  output wire full,
  output reg [PTR_W:0] count
);
  reg [TAG_W-1:0] mem [0:DEPTH-1];
  reg [PTR_W-1:0] rd_ptr, wr_ptr;
  assign empty = (count == 0);
  assign full = (count == DEPTH);
  assign head_tag = mem[rd_ptr];
  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin rd_ptr<=0; wr_ptr<=0; count<=0; end
    else if (clear) begin rd_ptr<=0; wr_ptr<=0; count<=0; end
    else begin
      if (push) begin
        mem[wr_ptr] <= push_tag;
        wr_ptr <= (wr_ptr == DEPTH-1) ? 0 : wr_ptr + 1'b1;
      end
      if (pop) rd_ptr <= (rd_ptr == DEPTH-1) ? 0 : rd_ptr + 1'b1;
      case ({push,pop})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: count <= count;
      endcase
    end
  end
endmodule
