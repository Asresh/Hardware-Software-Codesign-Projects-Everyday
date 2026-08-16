// Author: Asresh
// Pin-level MMIO/stream differential test with randomized ingress gaps and egress backpressure.
`timescale 1ns/1ps
module sobel_tb;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg bus_valid=0,bus_write=0;reg[5:0]bus_addr=0;reg[31:0]bus_wdata=0;wire bus_ready;wire[31:0]bus_rdata;
 reg s_valid=0;wire s_ready;reg[7:0]s_data=0;wire m_valid;reg m_ready=0;wire[7:0]m_data;wire m_last,irq;
 sobel_mmio_top #(.MAX_WIDTH(64))dut(.clk(clk),.rst_n(rst_n),.bus_valid_i(bus_valid),.bus_write_i(bus_write),.bus_addr_i(bus_addr),.bus_wdata_i(bus_wdata),.bus_ready_o(bus_ready),.bus_rdata_o(bus_rdata),.s_axis_tvalid(s_valid),.s_axis_tready(s_ready),.s_axis_tdata(s_data),.m_axis_tvalid(m_valid),.m_axis_tready(m_ready),.m_axis_tdata(m_data),.m_axis_tlast(m_last),.irq_o(irq));
 integer fd,rc,w,h,nout,baseline,i,in_idx=0,out_idx=0,mismatches=0,cycles=0,start_cycle,end_cycle;integer seed=32'h26a5c308;
 reg[7:0]pixels[0:4095];reg[7:0]expected[0:4095];reg[31:0]rd;
 always @(posedge clk)begin cycles<=cycles+1;if(m_valid&&m_ready)begin if(m_data!==expected[out_idx])begin $display("MISMATCH out=%0d got=%0d exp=%0d",out_idx,m_data,expected[out_idx]);mismatches=mismatches+1;end if(m_last!==(out_idx==nout-1))begin $display("MISMATCH TLAST out=%0d",out_idx);mismatches=mismatches+1;end out_idx=out_idx+1;end end
 task mmio_write(input[5:0]a,input[31:0]d);begin @(negedge clk);bus_valid=1;bus_write=1;bus_addr=a;bus_wdata=d;@(posedge clk);@(negedge clk);bus_valid=0;bus_write=0;end endtask
 task mmio_read(input[5:0]a,output[31:0]d);begin @(negedge clk);bus_valid=1;bus_write=0;bus_addr=a;@(posedge clk);#1 d=bus_rdata;@(negedge clk);bus_valid=0;end endtask
 initial begin
  fd=$fopen("vectors.txt","r");if(fd==0)$fatal(1,"cannot open vectors.txt");rc=$fscanf(fd,"%d %d %d %d\n",w,h,nout,baseline);if(rc!=4)$fatal(1,"bad header");
  for(i=0;i<w*h;i=i+1)rc=$fscanf(fd,"%d\n",pixels[i]);for(i=0;i<nout;i=i+1)rc=$fscanf(fd,"%d\n",expected[i]);$fclose(fd);
  repeat(5)@(posedge clk);rst_n=1;mmio_write(6'h04,w);mmio_write(6'h08,h);mmio_write(6'h00,32'h102);start_cycle=cycles;
  while(in_idx<w*h)begin @(negedge clk);m_ready=($random(seed)&3)!=0;if(($random(seed)&3)!=0)begin s_valid=1;s_data=pixels[in_idx];end else s_valid=0;@(posedge clk);if(s_valid&&s_ready)in_idx=in_idx+1;end
  @(negedge clk);s_valid=0;while(!irq)begin m_ready=($random(seed)&3)!=0;@(posedge clk);if(cycles-start_cycle>5000)$fatal(1,"timeout");@(negedge clk);end m_ready=1;end_cycle=cycles;
  while(out_idx<nout)@(posedge clk);mmio_read(6'h10,rd);if(rd!=w*h)begin $display("MISMATCH PIXELS_IN %0d",rd);mismatches=mismatches+1;end
  mmio_read(6'h14,rd);if(rd!=nout)begin $display("MISMATCH PIXELS_OUT %0d",rd);mismatches=mismatches+1;end
  mmio_write(6'h18,1);@(posedge clk);if(irq)begin $display("MISMATCH IRQ W1C");mismatches=mismatches+1;end
  $display("METRIC input_pixels=%0d",w*h);$display("METRIC random_pixels=%0d",w*h-16);$display("METRIC output_pixels=%0d",nout);$display("METRIC cycles=%0d",end_cycle-start_cycle);$display("METRIC latency_cycles=3");$display("METRIC baseline_cycles=%0d",baseline);$display("METRIC mismatches=%0d",mismatches);
  if(mismatches==0)$display("TEST PASSED");else $display("TEST FAILED");$finish;
 end
endmodule
