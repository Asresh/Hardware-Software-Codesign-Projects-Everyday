// Author: Asresh
`timescale 1ns/1ps
module replay_guard_tb;
reg clk=0,rst_n=0,bus_valid=0,bus_write=0;reg[7:0]bus_addr=0;reg[31:0]bus_wdata=0;wire bus_ready;wire[31:0]bus_rdata;wire irq;
integer cycles=0,seed=32'h28c0ffee,mismatches=0,fd,rv,count,i,op,ctx,epoch,ex_accept,ex_reason,ex_slot;integer exp_ac,exp_rc,exp_sc;
integer start_cycle,total_latency=0;reg[63:0]baseline;reg[31:0]n0,n1,n2,n3,result,actual_ac,actual_rc,actual_sc;reg[1023:0]line;
spdm_replay_guard_top dut(clk,rst_n,bus_valid,bus_write,bus_addr,bus_wdata,bus_ready,bus_rdata,irq);
always #5 clk=~clk; always @(posedge clk)cycles<=cycles+1;
task gap;integer g;begin g=$random(seed)&3;repeat(g)@(posedge clk);end endtask
task wr;input[7:0]a;input[31:0]d;begin gap;@(negedge clk);bus_addr=a;bus_wdata=d;bus_write=1;bus_valid=1;@(posedge clk);if(!bus_ready)begin $display("bus write timeout");mismatches=mismatches+1;end @(negedge clk);bus_valid=0;bus_write=0;end endtask
task rd;input[7:0]a;output[31:0]d;begin gap;@(negedge clk);bus_addr=a;bus_write=0;bus_valid=1;@(posedge clk);d=bus_rdata;@(negedge clk);bus_valid=0;end endtask
initial begin
 repeat(5)@(posedge clk);rst_n=1;fd=$fopen("vectors.txt","r");if(fd==0)$fatal(1,"vectors.txt missing");rv=$fgets(line,fd);rv=$fscanf(fd,"%d %d %d %d %d\n",count,baseline,exp_ac,exp_rc,exp_sc);if(rv!=5)$fatal(1,"bad header");
 for(i=0;i<count;i=i+1)begin
  rv=$fscanf(fd,"%d %d %d %h %h %h %h %d %d %d\n",op,ctx,epoch,n0,n1,n2,n3,ex_accept,ex_reason,ex_slot);if(rv!=10)$fatal(1,"bad vector %0d",i);
  wr(8'h04,(epoch<<5)|ctx);wr(8'h08,n0);wr(8'h0c,n1);wr(8'h10,n2);wr(8'h14,n3);start_cycle=cycles;wr(8'h00,32'h2|1|(op<<8));
  while(!irq)@(posedge clk);total_latency=total_latency+(cycles-start_cycle);rd(8'h18,result);
  if(result[0]!==ex_accept||result[3:1]!==ex_reason||result[8:4]!==ex_slot)begin $display("MISMATCH %0d got=%h exp a/r/s=%0d/%0d/%0d",i,result,ex_accept,ex_reason,ex_slot);mismatches=mismatches+1;end
  wr(8'h00,32'h0a);
 end
 rd(8'h1c,actual_ac);rd(8'h20,actual_rc);rd(8'h24,actual_sc);
 if(actual_ac!==exp_ac||actual_rc!==exp_rc||actual_sc!==exp_sc)begin $display("counter mismatch got %0d %0d %0d expected %0d %0d %0d",actual_ac,actual_rc,actual_sc,exp_ac,exp_rc,exp_sc);mismatches=mismatches+1;end
 $display("REQUESTS=%0d",count);$display("CYCLES=%0d",cycles-5);$display("AVG_LATENCY=%0f",1.0*total_latency/count);$display("THROUGHPUT=%0f",1.0*count/(cycles-5));$display("BASELINE_CYCLES=%0d",baseline);$display("SPEEDUP=%0f",1.0*baseline/(cycles-5));$display("MISMATCHES=%0d",mismatches);
 if(mismatches==0)$display("TEST PASSED");else $display("TEST FAILED");$fclose(fd);$finish;
end
endmodule
