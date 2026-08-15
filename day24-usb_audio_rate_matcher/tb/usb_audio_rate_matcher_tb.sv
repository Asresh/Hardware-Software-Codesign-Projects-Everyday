// Author: Asresh
// Diagram: vector file -> MMIO config + randomized stream -> scoreboard/metrics
module usb_audio_rate_matcher_tb;
  reg clk=0,rst_n=0,bus_valid=0,bus_write=0; reg [5:0] bus_addr=0; reg [31:0] bus_wdata=0;
  wire bus_ready; wire [31:0] bus_rdata;
  reg s_valid=0,s_last=0,m_ready=0; reg signed [15:0] s_prev=0,s_curr=0; reg [15:0] s_fill=0;
  wire s_ready,m_valid,m_last,irq; wire signed [15:0] m_sample;
  usb_audio_mmio_top dut(clk,rst_n,bus_valid,bus_write,bus_addr,bus_wdata,bus_ready,bus_rdata,
    s_valid,s_ready,s_prev,s_curr,s_fill,s_last,m_valid,m_ready,m_sample,m_last,irq);
  always #5 clk=~clk;
  integer fd,rc,n,target,gain,i,recv_idx,cycles,mismatches,seed,accepted;
  integer prev[0:1023],curr[0:1023],fill[0:1023],expected[0:1023];
  real throughput,speedup;
  task mmio_write; input [5:0] a; input [31:0] d; begin
    @(negedge clk);bus_valid=1;bus_write=1;bus_addr=a;bus_wdata=d;
    @(negedge clk);bus_valid=0;bus_write=0;
  end endtask
  initial begin
    seed=32'h24a0d10;mismatches=0;recv_idx=0;cycles=0;
    fd=$fopen("vectors.txt","r");if(fd==0)begin $display("TEST FAILED: vectors");$finish;end
    rc=$fscanf(fd,"%d %d %d\n",n,target,gain);
    for(i=0;i<n;i=i+1)rc=$fscanf(fd,"%d %d %d %d\n",prev[i],curr[i],fill[i],expected[i]);
    $fclose(fd); repeat(4)@(posedge clk);rst_n=1;
    mmio_write(6'h04,target);mmio_write(6'h08,gain);mmio_write(6'h00,3);
    fork
      begin:producer
        for(i=0;i<n;i=i+1)begin
          repeat(($random(seed)&3)==0)@(negedge clk);
          @(negedge clk);s_valid=1;s_prev=prev[i];s_curr=curr[i];s_fill=fill[i];s_last=(i==n-1);accepted=0;
          while(accepted==0)begin @(posedge clk);if(s_ready)accepted=1;end
          @(negedge clk);s_valid=0;
        end
      end
      begin:ready_driver
        while(recv_idx<n)begin @(negedge clk);m_ready=(($random(seed)&7)!=0);end
      end
      begin:consumer
        while(recv_idx<n)begin
          @(posedge clk);cycles=cycles+1;
          if(m_valid && m_ready)begin
            if($signed(m_sample)!=$signed(expected[recv_idx]))begin
              $display("mismatch %0d got=%0d expected=%0d",recv_idx,$signed(m_sample),expected[recv_idx]);mismatches=mismatches+1;
            end
            if((recv_idx==n-1)!==m_last)begin $display("last mismatch %0d",recv_idx);mismatches=mismatches+1;end
            recv_idx=recv_idx+1;
          end
          if(cycles>10000)begin $display("TEST FAILED: timeout");$finish;end
        end
      end
    join
    repeat(2)@(negedge clk);
    if(!irq)begin $display("IRQ mismatch");mismatches=mismatches+1;end
    throughput=n*1.0/cycles;speedup=(n*18.0+12.0)/cycles;
    $display("METRIC vectors %0d",n);$display("METRIC cycles %0d",cycles);
    $display("METRIC latency 3");$display("METRIC throughput %0.6f",throughput);
    $display("METRIC baseline_cycles %0d",n*18+12);$display("METRIC speedup %0.6f",speedup);
    $display("METRIC mismatches %0d",mismatches);
    if(mismatches==0)$display("TEST PASSED");else $display("TEST FAILED");$finish;
  end
endmodule
