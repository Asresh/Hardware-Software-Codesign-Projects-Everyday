// Author: Asresh
`timescale 1ns/1ps
module pcie_completion_store #(
  parameter TAG_COUNT = 8,
  parameter TAG_W = 3
)(
  input wire clk,
  input wire reset_n,
  input wire clear,
  input wire alloc_fire,
  input wire [TAG_W-1:0] alloc_tag,
  input wire [15:0] alloc_id,
  input wire [31:0] alloc_opaque,
  input wire completion_fire,
  input wire [TAG_W-1:0] completion_tag,
  input wire [1:0] completion_status,
  input wire [31:0] completion_data,
  input wire retire_fire,
  input wire [TAG_W-1:0] retire_tag,
  input wire [TAG_W-1:0] read_tag,
  output reg [TAG_COUNT-1:0] complete,
  output wire [15:0] read_id,
  output wire [31:0] read_opaque,
  output wire [1:0] read_status,
  output wire [31:0] read_data
);
  reg [15:0] ids [0:TAG_COUNT-1];
  reg [31:0] opaques [0:TAG_COUNT-1];
  reg [1:0] statuses [0:TAG_COUNT-1];
  reg [31:0] data [0:TAG_COUNT-1];
  assign read_id=ids[read_tag];
  assign read_opaque=opaques[read_tag];
  assign read_status=statuses[read_tag];
  assign read_data=data[read_tag];
  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) complete <= {TAG_COUNT{1'b0}};
    else if (clear) complete <= {TAG_COUNT{1'b0}};
    else begin
      if (retire_fire) complete[retire_tag] <= 1'b0;
      if (alloc_fire) begin
        ids[alloc_tag] <= alloc_id;
        opaques[alloc_tag] <= alloc_opaque;
        complete[alloc_tag] <= 1'b0;
      end
      if (completion_fire) begin
        statuses[completion_tag] <= completion_status;
        data[completion_tag] <= completion_data;
        complete[completion_tag] <= 1'b1;
      end
    end
  end
endmodule
