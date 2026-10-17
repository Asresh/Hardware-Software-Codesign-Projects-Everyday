// Author: Asresh
`timescale 1ns/1ps
module pcie_completion_reorder_engine #(
  parameter TAG_COUNT=8,
  parameter TAG_W=3,
  parameter PTR_W=3,
  parameter COUNT_W=32
)(
  input wire clk,
  input wire reset_n,
  input wire req_valid,
  output wire req_ready,
  input wire [15:0] req_id,
  input wire [31:0] req_opaque,
  output wire issue_valid,
  input wire issue_ready,
  output wire [TAG_W-1:0] issue_tag,
  output wire [15:0] issue_id,
  output wire [31:0] issue_opaque,
  input wire cpl_valid,
  output wire cpl_ready,
  input wire [TAG_W-1:0] cpl_tag,
  input wire [1:0] cpl_status,
  input wire [31:0] cpl_data,
  output wire out_valid,
  input wire out_ready,
  output wire [15:0] out_id,
  output wire [31:0] out_opaque,
  output wire [1:0] out_status,
  output wire [31:0] out_data,
  input wire tl_a_valid,
  output wire tl_a_ready,
  input wire tl_a_write,
  input wire [7:0] tl_a_addr,
  input wire [31:0] tl_a_data,
  output reg tl_d_valid,
  input wire tl_d_ready,
  output reg [31:0] tl_d_data,
  output reg tl_d_error,
  output reg irq
);
  localparam A_CTRL=8'h00, A_STATUS=8'h04, A_TARGET=8'h08,
             A_ISSUED=8'h0c, A_COMPLETED=8'h10, A_RETIRED=8'h14,
             A_OOO=8'h18, A_ERRORS=8'h1c, A_HIGH_WATER=8'h20;
  reg enabled;
  reg [COUNT_W-1:0] target_count, issued_count, completed_count, retired_count;
  reg [COUNT_W-1:0] ooo_count, error_count, high_water;
  wire free_valid, fifo_empty, fifo_full;
  wire [TAG_W-1:0] free_tag, head_tag;
  wire [TAG_COUNT-1:0] busy, complete;
  wire [PTR_W:0] fifo_count;
  wire req_fire, retire_fire, cpl_fire, cpl_good;
  wire clear = tl_a_valid && tl_a_ready && tl_a_write && tl_a_addr==A_CTRL && tl_a_data[1];
  wire ctrl_write = tl_a_valid && tl_a_ready && tl_a_write && tl_a_addr==A_CTRL;
  wire target_write = tl_a_valid && tl_a_ready && tl_a_write && tl_a_addr==A_TARGET;

  assign issue_valid = req_valid && enabled && free_valid && !fifo_full;
  assign req_ready = enabled && free_valid && !fifo_full && issue_ready;
  assign issue_tag=free_tag;
  assign issue_id=req_id;
  assign issue_opaque=req_opaque;
  assign req_fire=req_valid && req_ready;
  assign cpl_ready=enabled;
  assign cpl_fire=cpl_valid && cpl_ready;
  assign cpl_good=cpl_fire && busy[cpl_tag] && !complete[cpl_tag];
  assign out_valid=!fifo_empty && complete[head_tag];
  assign retire_fire=out_valid && out_ready;
  assign tl_a_ready=!tl_d_valid || tl_d_ready;

  pcie_tag_allocator #(.TAG_COUNT(TAG_COUNT),.TAG_W(TAG_W)) u_tags(
    .clk(clk),.reset_n(reset_n),.clear(clear),.free_valid(free_valid),.free_tag(free_tag),
    .alloc_fire(req_fire),.free_fire(retire_fire),.free_return_tag(head_tag),.busy(busy));
  pcie_order_fifo #(.DEPTH(TAG_COUNT),.TAG_W(TAG_W),.PTR_W(PTR_W)) u_order(
    .clk(clk),.reset_n(reset_n),.clear(clear),.push(req_fire),.push_tag(free_tag),
    .pop(retire_fire),.head_tag(head_tag),.empty(fifo_empty),.full(fifo_full),.count(fifo_count));
  pcie_completion_store #(.TAG_COUNT(TAG_COUNT),.TAG_W(TAG_W)) u_store(
    .clk(clk),.reset_n(reset_n),.clear(clear),.alloc_fire(req_fire),.alloc_tag(free_tag),
    .alloc_id(req_id),.alloc_opaque(req_opaque),.completion_fire(cpl_good),
    .completion_tag(cpl_tag),.completion_status(cpl_status),.completion_data(cpl_data),
    .retire_fire(retire_fire),.retire_tag(head_tag),.read_tag(head_tag),.complete(complete),
    .read_id(out_id),.read_opaque(out_opaque),.read_status(out_status),.read_data(out_data));

  always @* begin
    tl_d_data=32'd0;
    tl_d_error=1'b0;
    case(tl_a_addr)
      A_CTRL: tl_d_data={30'd0,1'b0,enabled};
      A_STATUS: tl_d_data={15'd0,fifo_count,7'd0,irq};
      A_TARGET: tl_d_data=target_count;
      A_ISSUED: tl_d_data=issued_count;
      A_COMPLETED: tl_d_data=completed_count;
      A_RETIRED: tl_d_data=retired_count;
      A_OOO: tl_d_data=ooo_count;
      A_ERRORS: tl_d_data=error_count;
      A_HIGH_WATER: tl_d_data=high_water;
      default: begin tl_d_data=32'd0; tl_d_error=1'b1; end
    endcase
  end

  always @(posedge clk or negedge reset_n) begin
    if(!reset_n) begin
      enabled<=0; target_count<=0; issued_count<=0; completed_count<=0;
      retired_count<=0; ooo_count<=0; error_count<=0; high_water<=0;
      tl_d_valid<=0; irq<=0;
    end else begin
      if(tl_d_valid && tl_d_ready) tl_d_valid<=0;
      if(tl_a_valid && tl_a_ready) tl_d_valid<=1;
      if(ctrl_write) begin
        enabled<=tl_a_data[0];
        if(tl_a_data[2]) irq<=0;
      end
      if(target_write) target_count<=tl_a_data;
      if(clear) begin
        issued_count<=0; completed_count<=0; retired_count<=0;
        ooo_count<=0; error_count<=0; high_water<=0; irq<=0;
      end else begin
        if(req_fire) issued_count<=issued_count+1'b1;
        if(cpl_good) begin
          completed_count<=completed_count+1'b1;
          if(!fifo_empty && cpl_tag!=head_tag) ooo_count<=ooo_count+1'b1;
        end else if(cpl_fire) error_count<=error_count+1'b1;
        if(req_fire && !retire_fire && fifo_count+1'b1>high_water)
          high_water<=fifo_count+1'b1;
        if(retire_fire) begin
          retired_count<=retired_count+1'b1;
          if(target_count!=0 && retired_count+1'b1>=target_count) irq<=1;
        end
      end
    end
  end
endmodule
