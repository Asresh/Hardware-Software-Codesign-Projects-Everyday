// Author: Asresh
`timescale 1ns/1ps
module vibration_goertzel_tb;
    localparam SAMPLE_W = 12;
    reg clk = 0;
    reg rst = 1;
    reg wb_cyc = 0, wb_stb = 0, wb_we = 0;
    reg [4:0] wb_adr = 0;
    reg [31:0] wb_wdata = 0;
    wire [31:0] wb_rdata;
    wire wb_ack;
    reg [SAMPLE_W-1:0] tdata = 0;
    reg tlast = 0, tvalid = 0;
    wire tready;
    wire irq;
    integer cycles = 0;
    integer errors = 0;
    integer checks = 0;
    integer seed = 32'h36c0de;
    integer samples [0:63];
    integer coeff [0:3];
    reg signed [63:0] rs1 [0:3];
    reg signed [63:0] rs2 [0:3];
    reg signed [63:0] rn;
    reg signed [63:0] rp;
    reg [63:0] expected_power;
    integer expected_bin;
    reg [31:0] rd_lo, rd_hi, rd_bin;
    integer frame, n, b, idle;

    always #5 clk = ~clk;
    always @(posedge clk) if (!rst) cycles <= cycles + 1;

    vibration_goertzel_top dut (
        .clk(clk), .rst(rst),
        .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb), .wb_we_i(wb_we),
        .wb_adr_i(wb_adr), .wb_dat_i(wb_wdata), .wb_dat_o(wb_rdata), .wb_ack_o(wb_ack),
        .s_axis_tdata(tdata), .s_axis_tlast(tlast), .s_axis_tvalid(tvalid), .s_axis_tready(tready),
        .irq_o(irq)
    );

    task wb_write(input [4:0] addr, input [31:0] data);
    begin
        @(negedge clk); wb_adr = addr; wb_wdata = data; wb_we = 1; wb_cyc = 1; wb_stb = 1;
        @(posedge clk); checks = checks + 1; if (!wb_ack) begin errors = errors + 1; $display("WB write did not acknowledge"); end
        @(negedge clk); wb_cyc = 0; wb_stb = 0; wb_we = 0;
    end endtask

    task wb_read(input [4:0] addr, output [31:0] data);
    begin
        @(negedge clk); wb_adr = addr; wb_we = 0; wb_cyc = 1; wb_stb = 1;
        @(posedge clk); data = wb_rdata; checks = checks + 1; if (!wb_ack) begin errors = errors + 1; $display("WB read did not acknowledge"); end
        @(negedge clk); wb_cyc = 0; wb_stb = 0;
    end endtask

    task send_sample(input integer value, input integer is_last);
    begin
        seed = seed * 1664525 + 1013904223;
        idle = (seed >> 4) & 3;
        repeat (idle) @(posedge clk);
        @(negedge clk); tdata = value[SAMPLE_W-1:0]; tlast = is_last[0]; tvalid = 1;
        while (!tready) @(posedge clk);
        @(posedge clk);
        @(negedge clk); tvalid = 0; tlast = 0;
    end endtask

    initial begin
        coeff[0] = 362; coeff[1] = 256; coeff[2] = 0; coeff[3] = -256;
        repeat (5) @(posedge clk);
        rst = 0;
        wb_write(0, 2);
        wb_write(7, coeff[0]); wb_write(8, coeff[1]); wb_write(9, coeff[2]); wb_write(10, coeff[3]);
        wb_write(0, 1);

        for (frame = 0; frame < 260; frame = frame + 1) begin
            for (n = 0; n < 64; n = n + 1) begin
                seed = seed * 1664525 + 1013904223;
                samples[n] = (seed & 2047) - 1024;
            end
            if (frame == 0) for (n = 0; n < 64; n = n + 1) samples[n] = 0;
            if (frame == 1) begin for (n = 0; n < 64; n = n + 1) samples[n] = 0; samples[0] = 2047; end
            if (frame == 2) for (n = 0; n < 64; n = n + 1) samples[n] = (n & 1) ? -2048 : 2047;
            if (frame == 3) for (n = 0; n < 64; n = n + 1) samples[n] = 2047;

            expected_power = 0; expected_bin = 0;
            for (b = 0; b < 4; b = b + 1) begin
                rs1[b] = 0; rs2[b] = 0;
                for (n = 0; n < 64; n = n + 1) begin
                    rn = samples[n] + ((coeff[b] * rs1[b]) >>> 8) - rs2[b];
                    rs2[b] = rs1[b]; rs1[b] = rn;
                end
                rp = rs1[b]*rs1[b] + rs2[b]*rs2[b] - ((coeff[b]*rs1[b]*rs2[b]) >>> 8);
                if ((b == 0) || ($unsigned(rp) > expected_power)) begin expected_power = rp; expected_bin = b; end
            end

            for (n = 0; n < 64; n = n + 1) send_sample(samples[n], n == 63);
            while (!irq) @(posedge clk);
            wb_read(4, rd_bin); wb_read(5, rd_lo); wb_read(6, rd_hi);
            checks = checks + 2;
            if (rd_bin[7:0] !== expected_bin[7:0]) begin errors = errors + 1; $display("frame %0d bin got %0d expected %0d", frame, rd_bin[7:0], expected_bin); end
            if ({rd_hi,rd_lo} !== expected_power) begin errors = errors + 1; $display("frame %0d power got %0d expected %0d", frame, {rd_hi,rd_lo}, expected_power); end
            wb_write(1, 1);
        end
        wb_read(2, rd_lo); checks = checks + 1; if (rd_lo != 16640) begin errors = errors + 1; $display("sample count %0d", rd_lo); end
        wb_read(3, rd_lo); checks = checks + 1; if (rd_lo != 260) begin errors = errors + 1; $display("frame count %0d", rd_lo); end
        if (errors == 0) $display("PASS: 260 frames (4 corner + 256 randomized), 16640 samples, %0d checks, 0 mismatches, %0d clocks", checks, cycles);
        else $display("FAIL: %0d errors across %0d checks", errors, checks);
        if (errors != 0) $fatal(1);
        $finish;
    end
endmodule
