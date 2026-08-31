// Author: Asresh
`timescale 1ns/1ps
module ml_topk_command_tb;
 reg clk=0,rst_n=0,mmio_valid=0,mmio_write=0;reg[7:0]mmio_addr=0;reg[31:0]mmio_wdata=0;
 wire mmio_ready;wire[31:0]mmio_rdata;wire mem_rd_valid;wire[15:0]mem_rd_addr;
 reg mem_rd_ready=0;wire[31:0]mem_rd_data;wire mem_wr_valid;wire[15:0]mem_wr_addr;wire[31:0]mem_wr_data;
 reg mem_wr_ready=0;wire irq;reg[31:0]memory[0:4095];reg signed[15:0]input_score[0:7];
 integer expected_v0[0:319],expected_i0[0:319],expected_v1[0:319],expected_i1[0:319];
 integer fd,count,baseline,n,j,rc,cycles,mismatches=0,latency_start=-1,first_latency=-1;
 reg[31:0]lfsr=32'h1badc0de;reg[31:0]got;
 always #5 clk=~clk;
 assign mem_rd_data=memory[mem_rd_addr>>2];
 ml_topk_command_top dut(.clk(clk),.rst_n(rst_n),.mmio_valid(mmio_valid),.mmio_write(mmio_write),
  .mmio_addr(mmio_addr),.mmio_wdata(mmio_wdata),.mmio_ready(mmio_ready),.mmio_rdata(mmio_rdata),
  .mem_rd_valid(mem_rd_valid),.mem_rd_addr(mem_rd_addr),.mem_rd_ready(mem_rd_ready),.mem_rd_data(mem_rd_data),
  .mem_wr_valid(mem_wr_valid),.mem_wr_addr(mem_wr_addr),.mem_wr_data(mem_wr_data),.mem_wr_ready(mem_wr_ready),.irq(irq));
 always @(posedge clk)begin
  if(!rst_n)begin lfsr<=32'h1badc0de;mem_rd_ready<=0;mem_wr_ready<=0;end else begin
   lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};mem_rd_ready<=lfsr[0]|lfsr[3];mem_wr_ready<=lfsr[1]|lfsr[5];
   if(mem_wr_valid&&mem_wr_ready)memory[mem_wr_addr>>2]<=mem_wr_data;
  end
 end
 task write_reg;input[7:0]a;input[31:0]d;begin @(negedge clk);mmio_valid=1;mmio_write=1;mmio_addr=a;mmio_wdata=d;
  @(negedge clk);mmio_valid=0;mmio_write=0;end endtask
 initial begin
  fd=$fopen("vectors.txt","r");if(!fd)begin $display("TEST FAILED vectors open");$finish;end
  rc=$fscanf(fd,"%d %d\n",count,baseline);if(rc!=2||count!=320)begin $display("TEST FAILED header");$finish;end
  for(n=0;n<count;n=n+1)begin
   for(j=0;j<8;j=j+1)rc=$fscanf(fd,"%d ",input_score[j]);
   rc=$fscanf(fd,"%d %d %d %d\n",expected_v0[n],expected_i0[n],expected_v1[n],expected_i1[n]);
   for(j=0;j<4;j=j+1)memory[(16'h0100>>2)+n*4+j]={input_score[j*2+1],input_score[j*2]};
  end $fclose(fd);
  repeat(4)@(posedge clk);rst_n=1;repeat(2)@(posedge clk);
  write_reg(8'h08,16'h0100);write_reg(8'h0c,16'h1800);write_reg(8'h10,count);write_reg(8'h00,3);
  cycles=0;
  while(!irq&&cycles<20000)begin @(posedge clk);cycles=cycles+1;
   if(mem_rd_valid&&mem_rd_ready&&mem_rd_addr==16'h010c)latency_start=cycles;
   if(first_latency<0&&mem_wr_valid)first_latency=cycles-latency_start;
  end
  if(!irq)begin $display("TEST FAILED timeout");$finish;end
  for(n=0;n<count;n=n+1)begin
   got=memory[(16'h1800>>2)+n*2];
   if($signed(got[15:0])!=expected_v0[n]||got[18:16]!=expected_i0[n])begin mismatches=mismatches+1;$display("mismatch %0d top0",n);end
   got=memory[(16'h1800>>2)+n*2+1];
   if($signed(got[15:0])!=expected_v1[n]||got[18:16]!=expected_i1[n])begin mismatches=mismatches+1;$display("mismatch %0d top1",n);end
  end
  if(dut.vector_no!=count-1)mismatches=mismatches+1;
  write_reg(8'h18,1);repeat(2)@(posedge clk);if(irq)mismatches=mismatches+1;
  write_reg(8'h10,0);write_reg(8'h00,3);repeat(3)@(posedge clk);
  if(!irq||!dut.error_sticky)mismatches=mismatches+1;
  write_reg(8'h18,1);
  $display("VECTORS=%0d MISMATCHES=%0d CYCLES=%0d THROUGHPUT=%f",count,mismatches,cycles,count*1.0/cycles);
  $display("FINAL_READ_TO_RESULT_LATENCY=%0d BASELINE_CYCLES=%0d SPEEDUP=%f",first_latency,baseline,baseline*1.0/cycles);
  if(mismatches==0)$display("TEST PASSED");else $display("TEST FAILED");$finish;
 end
endmodule
