// Author: Asresh
`timescale 1ns/1ps
module genomics_minimizer_tb;
  localparam N=320, W=8; reg clk=0,rst_n=0,avs_read=0,avs_write=0; reg [3:0] avs_address=0; reg [31:0] avs_writedata=0;
  wire [31:0] avs_readdata; reg sink_valid=0,sink_sop=0,sink_eop=0; reg [31:0] sink_data=0; wire sink_ready;
  wire source_valid; reg source_ready=0; wire [63:0] source_data; wire irq;
  reg [31:0] vectors[0:N-1], hist_hash[0:W-1], hist_pos[0:W-1], exp_hash[0:N-1], exp_pos[0:N-1];
  integer sent=0,received=0,cycles=0,count=0,i,j,seed=35,mismatches=0; reg [31:0] h,best,bpos,rc;
  genomics_minimizer_top #(.BASES(16),.WINDOW(W)) dut(.*,.sink_startofpacket(sink_sop),.sink_endofpacket(sink_eop));
  always #5 clk=~clk;
  function [31:0] revcomp; input [31:0] x; integer k; begin for(k=0;k<16;k=k+1) revcomp[2*k +: 2]=~x[2*(15-k) +: 2]; end endfunction
  function [31:0] mix; input [31:0] x; reg [63:0] p; begin x=x^(x>>16); p=x*32'h7feb352d; x=p[31:0]; mix=x^(x>>15); end endfunction
  task write_reg; input [3:0] a; input [31:0] d; begin @(negedge clk); avs_address=a;avs_writedata=d;avs_write=1;@(negedge clk);avs_write=0; end endtask
  always @(posedge clk) if(rst_n) begin
    cycles=cycles+1; source_ready <= (($random(seed)&3)!=0);
    if(sent<N && !sink_valid && (($random(seed)&3)!=0)) begin sink_valid<=1;sink_data<=vectors[sent];sink_sop<=(sent==0);sink_eop<=(sent==N-1); end
    if(sink_valid&&sink_ready) begin
      rc=revcomp(sink_data); h=mix(((sink_data<rc)?sink_data:rc)^32'h35c0ffee);
      for(i=W-1;i>0;i=i-1) begin hist_hash[i]=hist_hash[i-1];hist_pos[i]=hist_pos[i-1];end
      hist_hash[0]=h;hist_pos[0]=sent;count=count+1;
      if(count>=W) begin best=hist_hash[0];bpos=hist_pos[0];for(j=1;j<W;j=j+1)if(hist_hash[j]<best)begin best=hist_hash[j];bpos=hist_pos[j];end exp_hash[sent-W+1]=best;exp_pos[sent-W+1]=bpos;end
      sent=sent+1;sink_valid<=0;
    end
    if(source_valid&&source_ready) begin if(source_data[31:0]!==exp_hash[received]||source_data[63:32]!==exp_pos[received]) begin $display("mismatch %0d got=%h exp=%h/%0d",received,source_data,exp_hash[received],exp_pos[received]);mismatches=mismatches+1;end received=received+1;end
  end
  initial begin
    vectors[0]=0;vectors[1]=32'hffffffff;vectors[2]=32'h1b1b1b1b;vectors[3]=32'he4e4e4e4;for(i=4;i<N;i=i+1)vectors[i]=$random(seed);
    repeat(4)@(negedge clk);rst_n=1;write_reg(1,32'h35c0ffee);write_reg(0,1);
    wait(received==N-W+1);repeat(4)@(posedge clk);
    if(!irq)begin $display("IRQ missing");mismatches=mismatches+1;end
    if(mismatches==0)$display("PASS vectors=%0d corner=4 random=%0d outputs=%0d cycles=%0d mismatches=0",N,N-4,received,cycles);else $fatal(1,"FAIL mismatches=%0d",mismatches);
    $finish;
  end
  initial begin #2000000;$fatal(1,"timeout sent=%0d received=%0d",sent,received);end
endmodule
