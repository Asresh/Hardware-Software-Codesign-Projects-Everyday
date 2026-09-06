// Author: Asresh
`timescale 1ns/1ps
module gpu_tile_mask_compactor_tb;
  localparam N=320;
  reg clk=0, reset_n=0;
  reg s_axis_valid=0, s_axis_last=0; reg [63:0] s_axis_data=0; wire s_axis_ready;
  wire m_axis_valid; reg m_axis_ready=0; wire [31:0] m_axis_data; wire m_axis_last;
  reg hsel=0, hwrite=0, hready=1; reg [1:0] htrans=0; reg [7:0] haddr=0; reg [31:0] hwdata=0;
  wire [31:0] hrdata; wire hreadyout,hresp,irq;
  reg [63:0] vectors[0:N-1]; reg [31:0] expected[0:N-1];
  integer sent=0,received=0,cycles=0,i,j,seed=38,mismatches=0;
  integer ones,first,last; reg seen; reg [31:0] exp; reg [31:0] rd;
  gpu_tile_mask_compactor dut(.*);
  always #5 clk=~clk;
  task ahb_write; input [7:0] a; input [31:0] d; begin
    @(negedge clk); hsel=1;htrans=2'b10;hwrite=1;haddr=a;hwdata=d;
    @(negedge clk); hsel=0;htrans=0;hwrite=0;
  end endtask
  task ahb_read; input [7:0] a; output [31:0] d; begin
    @(negedge clk); hsel=1;htrans=2'b10;hwrite=0;haddr=a;
    @(posedge clk); #1 d=hrdata;
    @(negedge clk); hsel=0;htrans=0;
  end endtask
  always @(posedge clk) if(reset_n) begin
    cycles=cycles+1;
    m_axis_ready <= (($random(seed)&3)!=0);
    if(sent<N && !s_axis_valid && (($random(seed)&3)!=0)) begin
      s_axis_valid<=1; s_axis_data<=vectors[sent]; s_axis_last<=(sent==N-1);
    end
    if(s_axis_valid&&s_axis_ready) begin
      ones=0;first=0;last=0;seen=0;
      for(j=0;j<64;j=j+1) if(s_axis_data[j]) begin
        ones=ones+1; if(!seen)begin first=j;seen=1;end last=j;
      end
      exp=ones | (first<<7) | (last<<13) | ((!seen)<<19) | ((ones<=8)<<20);
      expected[sent]=exp; sent=sent+1; s_axis_valid<=0;
    end
    if(m_axis_valid&&m_axis_ready) begin
      if(m_axis_data!==expected[received]) begin
        $display("mismatch %0d got=%h expected=%h reduce=%0d/%0d/%0d empty=%b scan=%h",received,m_axis_data,expected[received],dut.active_count,dut.first_active,dut.last_active,dut.empty,dut.byte_counts);mismatches=mismatches+1;
      end
      if(m_axis_last!==(received==N-1)) begin $display("last mismatch %0d",received);mismatches=mismatches+1;end
      received=received+1;
    end
  end
  initial begin
    vectors[0]=64'd0; vectors[1]=~64'd0; vectors[2]=64'd1; vectors[3]=64'h8000000000000000;
    vectors[4]=64'h00000000000000ff; vectors[5]=64'hff00000000000000;
    vectors[6]=64'haaaaaaaaaaaaaaaa; vectors[7]=64'h5555555555555555;
    for(i=8;i<N;i=i+1) vectors[i]={$random(seed),$random(seed)};
    repeat(5)@(negedge clk);reset_n=1;ahb_write(8'h18,32'd8);ahb_write(8'h00,32'd1);
    wait(received==N); repeat(3)@(posedge clk);
    if(!irq)begin $display("IRQ missing");mismatches=mismatches+1;end
    ahb_read(8'h08,rd);if(rd!=N)begin $display("input count=%0d",rd);mismatches=mismatches+1;end
    ahb_read(8'h0c,rd);if(rd!=N)begin $display("output count=%0d",rd);mismatches=mismatches+1;end
    ahb_read(8'h10,rd);if(rd!=1)begin $display("batch count=%0d",rd);mismatches=mismatches+1;end
    ahb_read(8'h14,rd);if(rd!=1)begin $display("zero count=%0d",rd);mismatches=mismatches+1;end
    ahb_write(8'h00,32'd5);if(irq)begin $display("IRQ did not clear");mismatches=mismatches+1;end
    if(mismatches==0)$display("PASS vectors=%0d corner=8 random=%0d cycles=%0d checks=%0d mismatches=0",N,N-8,cycles,N*2+5);
    else $fatal(1,"FAIL mismatches=%0d",mismatches);
    $finish;
  end
  initial begin #2000000;$fatal(1,"timeout sent=%0d received=%0d",sent,received);end
endmodule
