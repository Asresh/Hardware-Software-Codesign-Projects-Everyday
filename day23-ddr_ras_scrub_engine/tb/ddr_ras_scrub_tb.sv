// Author: Asresh
// Descriptor-level memory model, random backpressure, corners, and differential checks.
`timescale 1ns/1ps
module ddr_ras_scrub_tb;
    localparam N=304;
    reg clk=0,rst_n=0,start=0; always #5 clk=~clk;
    reg [31:0] base=0,count=N; wire busy,irq; wire [31:0] corr_count,bad_count;
    wire rd_valid; reg rd_ready=0; wire [31:0] rd_addr; reg rsp_valid=0; reg [63:0] rsp_data=0;
    wire wr_valid; reg wr_ready=0; wire [31:0] wr_addr; wire [63:0] wr_data;
    reg [63:0] mem[0:N-1],expected_mem[0:N-1]; integer efixed[0:N-1],ebad[0:N-1];
    integer fd,rc,i,cycles,mismatches=0; reg [31:0] lfsr=32'h1badf00d;
    ddr_ras_scrub_top dut(.clk(clk),.rst_n(rst_n),.start_i(start),.irq_clear_i(1'b0),.desc_base_i(base),.desc_count_i(count),
      .busy_o(busy),.irq_o(irq),.corrected_count_o(corr_count),.uncorrectable_count_o(bad_count),
      .rd_req_valid_o(rd_valid),.rd_req_ready_i(rd_ready),.rd_req_addr_o(rd_addr),
      .rd_rsp_valid_i(rsp_valid),.rd_rsp_data_i(rsp_data),.wr_req_valid_o(wr_valid),
      .wr_req_ready_i(wr_ready),.wr_req_addr_o(wr_addr),.wr_req_data_o(wr_data));
    always @(posedge clk) begin
        lfsr <= {lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        rd_ready <= lfsr[0] | lfsr[3]; wr_ready <= lfsr[1] | lfsr[4]; rsp_valid <= 0;
        if(rd_valid&&rd_ready) begin rsp_valid<=1; rsp_data<=mem[rd_addr>>3]; end
        if(wr_valid&&wr_ready) mem[wr_addr>>3]<=wr_data;
    end
    initial begin
        fd=$fopen("vectors.txt","r"); if(!fd) begin $display("TEST FAILED vectors");$finish;end
        rc=$fscanf(fd,"%d\n",i); if(i!=N) begin $display("TEST FAILED count");$finish;end
        for(i=0;i<N;i=i+1) begin rc=$fscanf(fd,"%h %h %d %d\n",mem[i],expected_mem[i],efixed[i],ebad[i]); if(rc!=4)$finish; end
        $fclose(fd); repeat(4)@(posedge clk);rst_n<=1;@(posedge clk);start<=1;@(posedge clk);start<=0;
        cycles=0; while(!irq&&cycles<10000) begin @(posedge clk);cycles=cycles+1;end
        if(!irq) begin $display("TEST FAILED timeout");$finish;end
        @(posedge clk);
        for(i=0;i<N;i=i+1) if(mem[i][38:0]!==expected_mem[i][38:0]) begin mismatches=mismatches+1;if(mismatches<8)$display("mismatch %0d got=%h exp=%h",i,mem[i],expected_mem[i]);end
        if(corr_count!==152)begin $display("corrected count mismatch %0d",corr_count);mismatches=mismatches+1;end
        if(bad_count!==76)begin $display("uncorrectable count mismatch %0d",bad_count);mismatches=mismatches+1;end
        $display("VECTORS=%0d",N);$display("MISMATCHES=%0d",mismatches);$display("CYCLES=%0d",cycles);
        $display("LATENCY_CYCLES=%0d",cycles);$display("THROUGHPUT_WORDS_PER_CYCLE=%0.6f",N*1.0/cycles);
        $display("BASELINE_CYCLES=27986");$display("SPEEDUP=%0.3f",27986.0/cycles);
        if(mismatches==0)$display("TEST PASSED");else $display("TEST FAILED");$finish;
    end
endmodule
