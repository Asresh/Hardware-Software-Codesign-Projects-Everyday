// Author: Asresh
`timescale 1ns/1ps
module serdes_eye_margin_tb;
    reg clk = 0, rst_n = 0;
    reg psel = 0, penable = 0, pwrite = 0;
    reg [7:0] paddr = 0; reg [31:0] pwdata = 0;
    wire [31:0] prdata; wire pready, pslverr;
    reg sample_valid = 0; wire sample_ready;
    reg [6:0] sample_phase = 0; reg [15:0] sample_errors = 0; reg sample_last = 0;
    wire irq;
    integer scan_v[0:319], limit_v[0:319], phase_v[0:319], errors_v[0:319], last_v[0:319];
    integer best_start_v[0:319], best_len_v[0:319], count_v[0:319];
    integer fd, rc, i, scan, base, count, cycles, total_cycles, mismatches, accepted;
    integer first_accept_cycle, irq_cycle, total_latency;
    reg [31:0] rd;
    reg [1023:0] header_line;
    reg [15:0] lfsr = 16'h30a5;
    always #5 clk = ~clk;
    always @(posedge clk) lfsr <= {lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    serdes_eye_margin_top dut (.*);
    task apb_write(input [7:0] addr, input [31:0] data);
        begin
            @(negedge clk); psel=1; penable=0; pwrite=1; paddr=addr; pwdata=data;
            @(negedge clk); penable=1;
            @(negedge clk); psel=0; penable=0; pwrite=0;
        end
    endtask
    task apb_read(input [7:0] addr, output [31:0] data);
        begin
            @(negedge clk); psel=1; penable=0; pwrite=0; paddr=addr;
            @(negedge clk); penable=1; #1 data=prdata;
            @(negedge clk); psel=0; penable=0;
        end
    endtask
    initial begin
        fd = $fopen("vectors.txt","r");
        if (fd == 0) begin $display("TEST FAILED: vectors.txt missing"); $finish; end
        rc = $fgets(header_line,fd);
        for (i=0;i<320;i=i+1) begin
            rc = $fscanf(fd,"%d %d %d %d %d %d %d %d\n",scan_v[i],limit_v[i],phase_v[i],errors_v[i],last_v[i],best_start_v[i],best_len_v[i],count_v[i]);
            if (rc != 8) begin $display("TEST FAILED: vector parse at %0d",i); $finish; end
        end
        $fclose(fd);
        repeat (5) @(posedge clk); rst_n = 1;
        mismatches=0; total_cycles=0; total_latency=0; base=0;
        for (scan=0;scan<4;scan=scan+1) begin
            case(scan) 0: count=32; default: count=96; endcase
            apb_write(8'h08,limit_v[base]); apb_write(8'h00,32'h3);
            cycles=0; accepted=0; first_accept_cycle=-1; irq_cycle=-1;
            while (accepted < count) begin
                @(negedge clk); cycles=cycles+1;
                if (lfsr[1:0] != 0) begin
                    sample_valid=1; sample_phase=phase_v[base+accepted];
                    sample_errors=errors_v[base+accepted]; sample_last=last_v[base+accepted];
                end else sample_valid=0;
                @(posedge clk);
                if (sample_valid && sample_ready) begin
                    if (first_accept_cycle < 0) first_accept_cycle=cycles;
                    accepted=accepted+1;
                end
            end
            @(negedge clk); sample_valid=0; sample_last=0;
            while (!irq && cycles < 2000) begin @(negedge clk); cycles=cycles+1; end
            irq_cycle=cycles;
            if (!irq) begin $display("MISMATCH scan %0d timeout",scan); mismatches=mismatches+1; end
            apb_read(8'h0c,rd); if (rd[6:0] != best_start_v[base]) begin $display("MISMATCH scan %0d start got=%0d exp=%0d",scan,rd[6:0],best_start_v[base]); mismatches=mismatches+1; end
            apb_read(8'h10,rd); if (rd[8:0] != best_len_v[base]) begin $display("MISMATCH scan %0d length got=%0d exp=%0d",scan,rd[8:0],best_len_v[base]); mismatches=mismatches+1; end
            apb_read(8'h14,rd); if (rd[8:0] != count_v[base]) begin $display("MISMATCH scan %0d count got=%0d exp=%0d",scan,rd[8:0],count_v[base]); mismatches=mismatches+1; end
            total_cycles=total_cycles+cycles; total_latency=total_latency+(irq_cycle-first_accept_cycle+1);
            apb_write(8'h1c,1); base=base+count;
        end
        $display("METRIC vectors=320 scans=4 cycles=%0d throughput=%0f latency=%0f baseline_cycles=3592 speedup=%0f mismatches=%0d",total_cycles,320.0/total_cycles,total_latency/4.0,3592.0/total_cycles,mismatches);
        if (mismatches == 0) $display("TEST PASSED: 320 vectors, zero mismatches");
        else $display("TEST FAILED: %0d mismatches",mismatches);
        $finish;
    end
endmodule
