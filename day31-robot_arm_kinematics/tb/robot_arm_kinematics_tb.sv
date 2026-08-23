// Author: Asresh
`timescale 1ns/1ps
module robot_arm_kinematics_tb;
    reg clk=0, rst_n=0, spi_sclk=0, spi_cs_n=1, spi_mosi=0;
    wire spi_miso, irq;
    longint unsigned wall_clock=0;
    integer fd, jobs, job, rc, mismatches=0, total_joints=0;
    integer index, count, expected_x, expected_y, length, angle, i;
    integer got_x, got_y;
    longint unsigned baseline, baseline_total=0, measured_cycles, start_cycle, engine_total=0;
    reg [39:0] reply;
    reg [1023:0] header_line;
    real throughput, latency, speedup;
    robot_arm_kinematics_top dut(.clk(clk),.rst_n(rst_n),.spi_sclk(spi_sclk),.spi_cs_n(spi_cs_n),
        .spi_mosi(spi_mosi),.spi_miso(spi_miso),.irq(irq));
    always #5 clk=~clk;
    always @(posedge clk) wall_clock<=wall_clock+1;
    task automatic spi_exchange(input [39:0] tx, output [39:0] rx);
        integer bitn;
        begin
            rx=0; @(negedge clk); spi_cs_n=0; spi_sclk=0;
            for (bitn=39;bitn>=0;bitn=bitn-1) begin
                spi_mosi=tx[bitn]; repeat(2) @(negedge clk); spi_sclk=1;
                repeat(2) @(negedge clk); rx[bitn]=spi_miso; spi_sclk=0;
            end
            repeat(2) @(negedge clk); spi_cs_n=1; spi_mosi=0; repeat(4) @(posedge clk);
        end
    endtask
    task automatic command(input [7:0] op,input [31:0] data);
        reg [39:0] ignored;
        begin spi_exchange({op,data},ignored); end
    endtask
    task automatic read_reg(input [7:0] op,output [31:0] data);
        reg [39:0] first,second;
        begin
            spi_exchange({op,32'd0},first); spi_exchange({8'h00,32'd0},second);
            if (second[39:32]!==op) begin $display("bad SPI response opcode expected=%02x got=%02x",op,second[39:32]); mismatches=mismatches+1; end
            data=second[31:0];
        end
    endtask
    initial begin
        reg [31:0] data;
        repeat(8) @(posedge clk); rst_n=1; repeat(4) @(posedge clk);
        fd=$fopen("vectors.txt","r");
        if (fd==0) begin $display("TEST FAILED: cannot open vectors.txt"); $finish(1); end
        rc=$fgets(header_line,fd); rc=$fscanf(fd,"%d\n",jobs);
        if (rc!=1 || jobs<256) begin $display("TEST FAILED: invalid job count"); $finish(1); end
        command(8'h01,0); command(8'h10,0); read_reg(8'h40,data);
        if (!data[7]) begin $display("missing protocol error for zero-joint CONFIG"); mismatches=mismatches+1; end
        command(8'h01,0); read_reg(8'h40,data);
        if (data[7]) begin $display("RESET did not clear protocol error"); mismatches=mismatches+1; end
        start_cycle=wall_clock;
        for (job=0;job<jobs;job=job+1) begin
            rc=$fscanf(fd,"%d %d %d %d %d\n",index,count,expected_x,expected_y,baseline);
            if (rc!=5) begin $display("TEST FAILED: malformed job header %0d",job); $finish(1); end
            command(8'h01,0); command(8'h10,32'h100|count);
            for (i=0;i<count;i=i+1) begin
                rc=$fscanf(fd,"%d %d\n",length,angle);
                if (rc!=2) begin $display("TEST FAILED: malformed joint %0d/%0d",job,i); $finish(1); end
                command(8'h20,{length[15:0],angle[15:0]});
            end
            command(8'h30,0);
            i=0; while (!irq && i<1000) begin @(posedge clk); i=i+1; end
            if (!irq) begin $display("timeout job=%0d",job); mismatches=mismatches+1; end
            read_reg(8'h41,data); got_x=$signed(data);
            read_reg(8'h42,data); got_y=$signed(data);
            read_reg(8'h43,data); engine_total=engine_total+data;
            read_reg(8'h44,data);
            if (got_x!==expected_x || got_y!==expected_y || data!==count) begin
                $display("mismatch job=%0d x=%0d/%0d y=%0d/%0d joints=%0d/%0d",job,got_x,expected_x,got_y,expected_y,data,count);
                mismatches=mismatches+1;
            end
            read_reg(8'h40,data);
            if (!data[5] || !data[4] || data[3]) begin $display("bad completion status job=%0d status=%08x",job,data); mismatches=mismatches+1; end
            command(8'h50,0);
            if (irq) begin $display("IRQ ACK failed job=%0d",job); mismatches=mismatches+1; end
            baseline_total=baseline_total+baseline; total_joints=total_joints+count;
        end
        measured_cycles=wall_clock-start_cycle;
        throughput=$itor(total_joints)/$itor(engine_total);
        latency=$itor(engine_total)/$itor(jobs);
        speedup=$itor(baseline_total)/$itor(measured_cycles);
        $display("METRIC jobs=%0d joints=%0d cycles=%0d throughput=%0.6f latency=%0.3f baseline_cycles=%0d speedup=%0.6f mismatches=%0d",
            jobs,total_joints,measured_cycles,throughput,latency,baseline_total,speedup,mismatches);
        if (mismatches==0) $display("TEST PASSED: robotic chains match fixed-point reference");
        else $display("TEST FAILED: %0d mismatches",mismatches);
        $fclose(fd); $finish;
    end
endmodule
