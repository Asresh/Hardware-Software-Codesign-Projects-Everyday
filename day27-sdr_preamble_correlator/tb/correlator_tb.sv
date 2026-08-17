// Author: Asresh
// Differential testbench: directed corners plus 317 random vectors in two passes.
`timescale 1ns/1ps
module correlator_tb;
    localparam N = 320;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg bus_valid, bus_write;
    reg [7:0] bus_addr;
    reg [31:0] bus_wdata;
    wire bus_ready;
    wire [31:0] bus_rdata;
    reg [127:0] s_data;
    reg [15:0] s_tag;
    reg s_last, s_valid;
    wire s_ready;
    wire [63:0] m_data;
    wire m_last, m_valid;
    reg m_ready;
    wire irq;

    reg [127:0] vectors [0:N-1];
    reg [15:0] tags [0:N-1];
    reg lasts [0:N-1];
    reg [40:0] powers [0:N-1];
    reg detects [0:N-1];
    integer fd, rc, count, n, lane, ti, tq;
    reg [40:0] threshold;
    integer failures = 0;
    integer checked = 0;
    integer full_cycles = 0;
    integer full_latency = 0;
    reg [31:0] status_word;
    reg [31:0] read_w3, read_w2, read_w1, read_w0;
    reg [7:0] ti_store [0:7];
    reg [7:0] tq_store [0:7];

    sdr_correlator_top dut (
        .clk(clk), .rst_n(rst_n), .bus_valid(bus_valid), .bus_write(bus_write),
        .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_ready(bus_ready),
        .bus_rdata(bus_rdata), .s_axis_tdata(s_data), .s_axis_tuser(s_tag),
        .s_axis_tlast(s_last), .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .m_axis_tdata(m_data), .m_axis_tlast(m_last), .m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready), .irq(irq)
    );

    task mmio_write;
        input [7:0] addr;
        input [31:0] data;
        begin
            @(negedge clk); bus_addr = addr; bus_wdata = data;
            bus_write = 1; bus_valid = 1;
            @(negedge clk); bus_valid = 0; bus_write = 0;
        end
    endtask
    task mmio_read;
        input [7:0] addr;
        output [31:0] data;
        begin
            @(negedge clk); bus_addr = addr; bus_write = 0; bus_valid = 1;
            #1 data = bus_rdata;
            @(negedge clk); bus_valid = 0;
        end
    endtask
    task configure;
        begin
            mmio_write(8'h00, 32'h2);
            mmio_write(8'h08, threshold[31:0]);
            mmio_write(8'h0c, {23'd0, threshold[40:32]});
            for (lane = 0; lane < 8; lane = lane + 1)
                mmio_write(8'h40 + lane * 4, {16'd0, tq_store[lane], ti_store[lane]});
            mmio_write(8'h00, 32'h5);
        end
    endtask

    task run_pass;
        input random_stalls;
        integer sent, received, cycles, first_in_cycle;
        reg [31:0] lfsr;
        reg input_fire;
        begin
            sent = 0; received = 0; cycles = 0; first_in_cycle = -1;
            lfsr = 32'h51d27a31;
            s_valid = 0; m_ready = 0;
            while (received < count && cycles < 20000) begin
                @(negedge clk);
                lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                m_ready = random_stalls ? lfsr[2] : 1'b1;
                if (!s_valid && sent < count && (!random_stalls || lfsr[0])) begin
                    s_valid = 1;
                    s_data = vectors[sent];
                    s_tag = tags[sent];
                    s_last = lasts[sent];
                end
                @(posedge clk);
                cycles = cycles + 1;
                if (m_valid && m_ready) begin
                    if (m_data[56:41] !== tags[received] ||
                        m_data[40:0] !== powers[received] ||
                        m_data[57] !== detects[received] ||
                        m_last !== lasts[received]) begin
                        $display("MISMATCH pass=%0d index=%0d got=%h last=%b expected_tag=%h power=%h det=%b last=%b",
                                 random_stalls, received, m_data, m_last, tags[received],
                                 powers[received], detects[received], lasts[received]);
                        failures = failures + 1;
                    end
                    checked = checked + 1;
                    if (received == 0 && !random_stalls)
                        full_latency = cycles - first_in_cycle;
                    received = received + 1;
                end
                input_fire = s_valid && s_ready;
                if (input_fire) begin
                    if (sent == 0 && !random_stalls)
                        first_in_cycle = cycles;
                    sent = sent + 1;
                end
                #1;
                if (input_fire)
                    s_valid = 0;
            end
            s_valid = 0; m_ready = 1;
            if (cycles >= 20000) begin
                $display("TIMEOUT pass=%0d sent=%0d received=%0d", random_stalls, sent, received);
                failures = failures + 1;
            end
            if (!random_stalls)
                full_cycles = cycles;
            mmio_read(8'h04, status_word);
            if (!status_word[1] || !irq) begin
                $display("completion/IRQ missing status=%h irq=%b", status_word, irq);
                failures = failures + 1;
            end
            mmio_write(8'h1c, 1);
        end
    endtask

    initial begin
        bus_valid = 0; bus_write = 0; bus_addr = 0; bus_wdata = 0;
        s_data = 0; s_tag = 0; s_last = 0; s_valid = 0; m_ready = 0;
        fd = $fopen("vectors.txt", "r");
        if (fd == 0) begin $display("TEST FAILED: cannot open vectors.txt"); $finish; end
        rc = $fscanf(fd, "%d %h\n", count, threshold);
        if (rc != 2 || count != N) begin $display("TEST FAILED: bad header"); $finish; end
        for (lane = 0; lane < 8; lane = lane + 1) begin
            rc = $fscanf(fd, "%h %h", ti, tq);
            ti_store[lane] = ti[7:0]; tq_store[lane] = tq[7:0];
        end
        for (n = 0; n < N; n = n + 1) begin
            rc = $fscanf(fd, "%h %d %h %h %h %h %h %d\n",
                         tags[n], lasts[n], read_w3, read_w2, read_w1, read_w0,
                         powers[n], detects[n]);
            if (rc != 8) begin $display("TEST FAILED: parse vector %0d rc=%0d", n, rc); $finish; end
            vectors[n] = {read_w3, read_w2, read_w1, read_w0};
        end
        $fclose(fd);
        repeat (4) @(negedge clk); rst_n = 1;
        configure();
        run_pass(1);
        @(negedge clk); rst_n = 0; repeat (2) @(negedge clk); rst_n = 1;
        configure();
        run_pass(0);
        $display("METRICS vectors=%0d cycles=%0d latency=%0d baseline=%0d checks=%0d mismatches=%0d",
                 count, full_cycles, full_latency, count * 49, checked, failures);
        if (failures == 0 && checked == (2*N))
            $display("TEST PASSED: 320 vectors x 2 flow-control modes, zero mismatches");
        else
            $display("TEST FAILED: mismatches=%0d checks=%0d", failures, checked);
        $finish;
    end
endmodule
