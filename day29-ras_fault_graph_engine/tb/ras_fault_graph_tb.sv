// Author: Asresh
`timescale 1ns/1ps
module ras_fault_graph_tb;
reg clk=0,rst_n=0,bus_valid=0,bus_write=0;reg[7:0]bus_addr=0;reg[31:0]bus_wdata=0;wire bus_ready;wire[31:0]bus_rdata;wire irq;
integer cycles=0,seed_rng=32'h29c0ffee,mismatches=0,fd,rv,count,i,j,start_cycle,total_latency=0;integer expected_iter;reg[63:0]baseline;reg[31:0]seed,expected,actual,iters,visited,requests;reg[31:0]rows[0:15];reg[1023:0]line;
ras_fault_graph_top dut(clk,rst_n,bus_valid,bus_write,bus_addr,bus_wdata,bus_ready,bus_rdata,irq);
always #5 clk=~clk;always @(posedge clk)cycles<=cycles+1;
task gap;integer g;begin g=$random(seed_rng)&3;repeat(g)@(posedge clk);end endtask
task wr;input[7:0]a;input[31:0]d;begin gap;@(negedge clk);bus_addr=a;bus_wdata=d;bus_write=1;bus_valid=1;@(posedge clk);if(!bus_ready)mismatches=mismatches+1;@(negedge clk);bus_valid=0;bus_write=0;end endtask
task rd;input[7:0]a;output[31:0]d;begin gap;@(negedge clk);bus_addr=a;bus_write=0;bus_valid=1;@(posedge clk);d=bus_rdata;@(negedge clk);bus_valid=0;end endtask
function integer popcount;input[15:0]v;integer q;begin popcount=0;for(q=0;q<16;q=q+1)popcount=popcount+v[q];end endfunction
initial begin repeat(5)@(posedge clk);rst_n=1;fd=$fopen("vectors.txt","r");if(fd==0)$fatal(1,"vectors.txt missing");rv=$fscanf(fd,"%d %d\n",count,baseline);if(rv!=2)$fatal(1,"bad header");
 for(i=0;i<count;i=i+1)begin rv=$fscanf(fd,"%h",seed);for(j=0;j<16;j=j+1)rv=$fscanf(fd," %h",rows[j]);rv=$fscanf(fd," %h %d\n",expected,expected_iter);if(rv!=2)$fatal(1,"bad vector %0d",i);
  for(j=0;j<16;j=j+1)begin wr(8'h08,j);wr(8'h0c,rows[j]);end wr(8'h04,seed);start_cycle=cycles;wr(8'h00,3);while(!irq)@(posedge clk);total_latency=total_latency+(cycles-start_cycle);rd(8'h10,actual);rd(8'h14,iters);rd(8'h18,visited);
  if(actual[15:0]!==expected[15:0]||iters!==expected_iter||visited!==popcount(expected[15:0]))begin $display("MISMATCH %0d got=%h/%0d/%0d exp=%h/%0d",i,actual,iters,visited,expected,expected_iter);mismatches=mismatches+1;end wr(8'h00,10);
 end
 rd(8'h1c,requests);if(requests!==count)mismatches=mismatches+1;
 $display("GRAPHS=%0d",count);$display("CYCLES=%0d",cycles-5);$display("AVG_LATENCY=%0f",1.0*total_latency/count);$display("THROUGHPUT=%0f",1.0*count/(cycles-5));$display("BASELINE_CYCLES=%0d",baseline);$display("SPEEDUP=%0f",1.0*baseline/(cycles-5));$display("MISMATCHES=%0d",mismatches);if(mismatches==0)$display("TEST PASSED");else $display("TEST FAILED");$fclose(fd);$finish;
end
endmodule
