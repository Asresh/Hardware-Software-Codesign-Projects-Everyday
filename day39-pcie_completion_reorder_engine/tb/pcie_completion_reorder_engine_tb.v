// Author: Asresh
`timescale 1ns/1ps
module pcie_completion_reorder_engine_tb;
  localparam N=320, TAG_COUNT=8;
  reg clk=0, reset_n=0;
  reg req_valid=0; wire req_ready; reg [15:0] req_id=0; reg [31:0] req_opaque=0;
  wire issue_valid; reg issue_ready=0; wire [2:0] issue_tag; wire [15:0] issue_id; wire [31:0] issue_opaque;
  reg cpl_valid=0; wire cpl_ready; reg [2:0] cpl_tag=0; reg [1:0] cpl_status=0; reg [31:0] cpl_data=0;
  wire out_valid; reg out_ready=0; wire [15:0] out_id; wire [31:0] out_opaque,out_data; wire [1:0] out_status;
  reg tl_a_valid=0,tl_a_write=0,tl_d_ready=1; reg [7:0] tl_a_addr=0; reg [31:0] tl_a_data=0;
  wire tl_a_ready,tl_d_valid,tl_d_error,irq; wire [31:0] tl_d_data;
  reg [31:0] vectors[0:N-1]; reg active[0:TAG_COUNT-1];
  reg [15:0] active_id[0:TAG_COUNT-1]; reg [31:0] active_opaque[0:TAG_COUNT-1];
  integer sent=0,completed=0,received=0,cycles=0,mismatches=0,checks=0;
  integer i,k,seed=39,pick,start,ooo_observed=0; reg running=0; reg [31:0] rd;

  pcie_completion_reorder_engine dut(.*);
  always #5 clk=~clk;
  function [31:0] result_data;
    input [15:0] id; input [31:0] opaque; reg [31:0] salt;
    begin salt=id*32'h9e3779b9; result_data=opaque^salt^(salt>>13); end
  endfunction
  task tl_write; input [7:0] a; input [31:0] d; begin
    @(negedge clk); tl_a_valid=1;tl_a_write=1;tl_a_addr=a;tl_a_data=d;
    while(!tl_a_ready) @(negedge clk);
    @(negedge clk); tl_a_valid=0;tl_a_write=0;
  end endtask
  task tl_read; input [7:0] a; output [31:0] d; begin
    @(negedge clk); tl_a_valid=1;tl_a_write=0;tl_a_addr=a;
    while(!tl_a_ready) @(negedge clk);
    @(posedge clk); #1 d=tl_d_data;
    @(negedge clk); tl_a_valid=0;
  end endtask
  task invalid_completion; input [2:0] tag; begin
    @(negedge clk); cpl_valid=1;cpl_tag=tag;cpl_status=3;cpl_data=32'hbad0c0de;
    @(posedge clk); while(!cpl_ready) @(posedge clk);
    @(negedge clk); cpl_valid=0;
  end endtask

  always @(negedge clk) if(reset_n) begin
    issue_ready=(($random(seed)&3)!=0);
    out_ready=(($random(seed)&3)!=0);
  end

  always @(posedge clk) if(reset_n) begin
    if(running) cycles=cycles+1;
    if(issue_valid&&issue_ready) begin
      active[issue_tag]=1; active_id[issue_tag]=issue_id; active_opaque[issue_tag]=issue_opaque;
    end
    if(cpl_valid&&cpl_ready&&active[cpl_tag]) begin
      if(cpl_tag!=dut.head_tag) ooo_observed=ooo_observed+1;
      active[cpl_tag]=0; completed=completed+1;
    end
    if(out_valid&&out_ready) begin
      if(out_id!==received[15:0]) begin $display("id mismatch %0d got=%0d",received,out_id);mismatches=mismatches+1;end checks=checks+1;
      if(out_opaque!==vectors[received]) begin $display("opaque mismatch %0d",received);mismatches=mismatches+1;end checks=checks+1;
      if(out_status!==(received&3)) begin $display("status mismatch %0d",received);mismatches=mismatches+1;end checks=checks+1;
      if(out_data!==result_data(received[15:0],vectors[received])) begin $display("data mismatch %0d got=%h exp=%h",received,out_data,result_data(received[15:0],vectors[received]));mismatches=mismatches+1;end checks=checks+1;
      received=received+1;
    end
  end

  always @(negedge clk) if(running) begin
    if(cpl_valid && cpl_ready) cpl_valid=0;
    if(!cpl_valid && sent>=TAG_COUNT && (($random(seed)&3)!=0)) begin
      pick=-1; start=$random(seed)&7;
      for(k=0;k<TAG_COUNT;k=k+1) if(pick<0 && active[(start+k)&7]) pick=(start+k)&7;
      if(pick>=0) begin
        cpl_valid=1; cpl_tag=pick[2:0]; cpl_status=active_id[pick][1:0];
        cpl_data=result_data(active_id[pick],active_opaque[pick]);
      end
    end
  end

  initial begin
    for(i=0;i<TAG_COUNT;i=i+1) active[i]=0;
    vectors[0]=0; vectors[1]=32'hffffffff; vectors[2]=1; vectors[3]=32'h80000000;
    vectors[4]=32'haaaaaaaa; vectors[5]=32'h55555555; vectors[6]=32'hdeadbeef; vectors[7]=32'h01020304;
    for(i=8;i<N;i=i+1) vectors[i]=$random(seed);
    repeat(5)@(negedge clk);reset_n=1;
    tl_write(8'h08,N); tl_write(8'h00,32'd1);
    invalid_completion(3'd7); invalid_completion(3'd6);
    running=1;
    while(sent<N) begin
      @(negedge clk);
      if(!req_valid) begin req_valid=1;req_id=sent[15:0];req_opaque=vectors[sent];end
      @(posedge clk);
      if(req_valid&&req_ready) begin sent=sent+1; @(negedge clk); req_valid=0; end
    end
    wait(received==N); running=0; repeat(3)@(posedge clk);
    if(!irq)begin $display("IRQ missing");mismatches=mismatches+1;end checks=checks+1;
    tl_read(8'h0c,rd);if(rd!=N)begin $display("issued=%0d",rd);mismatches=mismatches+1;end checks=checks+1;
    tl_read(8'h10,rd);if(rd!=N)begin $display("completed=%0d",rd);mismatches=mismatches+1;end checks=checks+1;
    tl_read(8'h14,rd);if(rd!=N)begin $display("retired=%0d",rd);mismatches=mismatches+1;end checks=checks+1;
    tl_read(8'h18,rd);if(rd==0||rd!=ooo_observed)begin $display("ooo=%0d observed=%0d",rd,ooo_observed);mismatches=mismatches+1;end checks=checks+1;
    tl_read(8'h1c,rd);if(rd!=2)begin $display("errors=%0d",rd);mismatches=mismatches+1;end checks=checks+1;
    tl_read(8'h20,rd);if(rd!=TAG_COUNT)begin $display("high_water=%0d",rd);mismatches=mismatches+1;end checks=checks+1;
    tl_read(8'h24,rd);if(!tl_d_error)begin $display("unmapped access not rejected");mismatches=mismatches+1;end checks=checks+1;
    tl_write(8'h00,32'd5);if(irq)begin $display("IRQ did not clear");mismatches=mismatches+1;end checks=checks+1;
    if(mismatches==0)$display("PASS vectors=%0d corner=8 random=%0d cycles=%0d out_of_order=%0d protocol_errors=2 checks=%0d mismatches=0",N,N-8,cycles,ooo_observed,checks);
    else $fatal(1,"FAIL mismatches=%0d",mismatches);
    $finish;
  end
  initial begin #3000000;$fatal(1,"timeout sent=%0d completed=%0d received=%0d",sent,completed,received);end
endmodule
