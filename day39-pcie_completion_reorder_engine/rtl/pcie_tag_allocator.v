// Author: Asresh
`timescale 1ns/1ps
module pcie_tag_allocator #(
  parameter TAG_COUNT = 8,
  parameter TAG_W = 3
)(
  input wire clk,
  input wire reset_n,
  input wire clear,
  output reg free_valid,
  output reg [TAG_W-1:0] free_tag,
  input wire alloc_fire,
  input wire free_fire,
  input wire [TAG_W-1:0] free_return_tag,
  output reg [TAG_COUNT-1:0] busy
);
  integer i;
  always @* begin
    free_valid = 1'b0;
    free_tag = {TAG_W{1'b0}};
    for (i=TAG_COUNT-1; i>=0; i=i-1)
      if (!busy[i]) begin free_valid=1'b1; free_tag=i[TAG_W-1:0]; end
  end
  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) busy <= {TAG_COUNT{1'b0}};
    else if (clear) busy <= {TAG_COUNT{1'b0}};
    else begin
      if (free_fire) busy[free_return_tag] <= 1'b0;
      if (alloc_fire) busy[free_tag] <= 1'b1;
    end
  end
endmodule
